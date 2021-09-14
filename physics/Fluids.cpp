#include "Fluids.hpp"
#include "FileUtils.hpp"
#include "Logging.hpp"

#include <ctime>
#include <iomanip>
#include <iostream>
#include <sstream>

using namespace Physics;

#define PROGRAM_FLUIDS "fluids"

#define KERNEL_INFINITE_POS "infPosVerts"
#define KERNEL_RANDOM_POS "randPosVerts"
#define KERNEL_UPDATE_POS_BOUNCING "updatePosWithBouncingWalls"
#define KERNEL_UPDATE_POS_CYCLIC "updatePosWithCyclicWalls"
#define KERNEL_UPDATE_VEL "updateVel"
#define KERNEL_FLUSH_GRID_DETECTOR "flushGridDetector"
#define KERNEL_FILL_GRID_DETECTOR "fillGridDetector"
#define KERNEL_RESET_CAMERA_DIST "resetCameraDist"
#define KERNEL_FILL_CAMERA_DIST "fillCameraDist"
#define KERNEL_RESET_CELL_ID "resetCellIDs"
#define KERNEL_FILL_CELL_ID "fillCellIDs"
#define KERNEL_FLUSH_START_END_CELL "flushStartEndCell"
#define KERNEL_FILL_START_CELL "fillStartCell"
#define KERNEL_FILL_END_CELL "fillEndCell"
#define KERNEL_ADJUST_END_CELL "adjustEndCell"

#define KERNEL_PREDICT_POS "predictPosition"
#define KERNEL_DENSITY "computeFluidDensity"
#define KERNEL_CONSTRAINT_FACTOR "computeConstraintFactor"
#define KERNEL_CONSTRAINT_CORRECTION "computeConstraintCorrection"
#define KERNEL_CORRECT_POS "correctPosition"

#define MAX_NB_JACOBI_ITERS 3

Fluids::Fluids(ModelParams params)
    : Model(params)
    , m_scaleAlignment(1.6f)
    , m_scaleCohesion(1.45f)
    , m_scaleSeparation(1.6f)
    , m_activeAlignment(true)
    , m_activeSeparation(true)
    , m_activeCohesion(true)
    , m_simplifiedMode(true)
    , m_maxNbPartsInCell(1000)
    , m_radixSort(params.maxNbParticles)
    , m_target(std::make_unique<Target>(params.boxSize))
{
  createProgram();

  createBuffers();

  createKernels();

  m_init = true;

  reset();
}

bool Fluids::createProgram() const
{
  CL::Context& clContext = CL::Context::Get();

  std::ostringstream clBuildOptions;
  clBuildOptions << "-DEFFECT_RADIUS_SQUARED=" << (int)(m_boxSize * m_boxSize / (m_gridRes * m_gridRes));
  clBuildOptions << " -DABS_WALL_POS=" << std::fixed << std::setprecision(2)
                 << std::setfill('0') << m_boxSize / 2.0f << "f";
  clBuildOptions << " -DGRID_RES=" << m_gridRes;
  clBuildOptions << " -DGRID_NUM_CELLS=" << m_nbCells;
  clBuildOptions << " -DNUM_MAX_PARTS_IN_CELL=" << m_maxNbPartsInCell;

  clContext.createProgram(PROGRAM_FLUIDS, "fluids.cl", clBuildOptions.str());

  return true;
}

bool Fluids::createBuffers() const
{
  CL::Context& clContext = CL::Context::Get();

  clContext.createGLBuffer("u_cameraPos", m_cameraVBO, CL_MEM_READ_ONLY);
  clContext.createGLBuffer("p_pos", m_particleVBO, CL_MEM_READ_WRITE);
  clContext.createGLBuffer("c_partDetector", m_gridVBO, CL_MEM_READ_WRITE);

  clContext.createBuffer("p_predPos", 4 * m_maxNbParticles * sizeof(float), CL_MEM_READ_WRITE);
  clContext.createBuffer("p_corrPos", 4 * m_maxNbParticles * sizeof(float), CL_MEM_READ_WRITE);
  clContext.createBuffer("p_vel", 4 * m_maxNbParticles * sizeof(float), CL_MEM_READ_WRITE);
  clContext.createBuffer("p_cellID", m_maxNbParticles * sizeof(unsigned int), CL_MEM_READ_WRITE);
  clContext.createBuffer("p_cameraDist", m_maxNbParticles * sizeof(unsigned int), CL_MEM_READ_WRITE);

  clContext.createBuffer("c_startEndPartID", 2 * m_nbCells * sizeof(unsigned int), CL_MEM_READ_WRITE);

  return true;
}

bool Fluids::createKernels() const
{
  CL::Context& clContext = CL::Context::Get();

  // Init only
  clContext.createKernel(PROGRAM_FLUIDS, KERNEL_INFINITE_POS, { "p_pos" });
  clContext.createKernel(PROGRAM_FLUIDS, KERNEL_RANDOM_POS, { "p_pos", "p_vel" });

  // For rendering purpose only
  clContext.createKernel(PROGRAM_FLUIDS, KERNEL_FLUSH_GRID_DETECTOR, { "c_partDetector" });
  clContext.createKernel(PROGRAM_FLUIDS, KERNEL_FILL_GRID_DETECTOR, { "p_pos", "c_partDetector" });
  clContext.createKernel(PROGRAM_FLUIDS, KERNEL_RESET_CAMERA_DIST, { "p_cameraDist" });
  clContext.createKernel(PROGRAM_FLUIDS, KERNEL_FILL_CAMERA_DIST, { "p_pos", "u_cameraPos", "p_cameraDist" });

  // Radix Sort based on 3D grid, using predicted positions, not corrected ones
  clContext.createKernel(PROGRAM_FLUIDS, KERNEL_RESET_CELL_ID, { "p_cellID" });
  clContext.createKernel(PROGRAM_FLUIDS, KERNEL_FILL_CELL_ID, { "p_predPos", "p_cellID" });

  clContext.createKernel(PROGRAM_FLUIDS, KERNEL_FLUSH_START_END_CELL, { "c_startEndPartID" });
  clContext.createKernel(PROGRAM_FLUIDS, KERNEL_FILL_START_CELL, { "p_cellID", "c_startEndPartID" });
  clContext.createKernel(PROGRAM_FLUIDS, KERNEL_FILL_END_CELL, { "p_cellID", "c_startEndPartID" });
  clContext.createKernel(PROGRAM_FLUIDS, KERNEL_ADJUST_END_CELL, { "c_startEndPartID" });

  // Position Based Fluids
  /// Position prediction
  clContext.createKernel(PROGRAM_FLUIDS, KERNEL_PREDICT_POS, { "p_pos", "p_vel", "", "p_predPos" });

  /// Jacobi solver to correct position
  clContext.createKernel(PROGRAM_FLUIDS, KERNEL_DENSITY, { "p_predPos", "p_density" });
  clContext.createKernel(PROGRAM_FLUIDS, KERNEL_CONSTRAINT_FACTOR, { "p_density", "p_predPos", "p_corrPos" });
  clContext.createKernel(PROGRAM_FLUIDS, KERNEL_CONSTRAINT_CORRECTION, { "p_predPos", "p_density", "p_corrPos" });
  clContext.createKernel(PROGRAM_FLUIDS, KERNEL_CORRECT_POS, { "p_corrPos", "p_vel", "p_predPos" });

  /// Velocity and position update
  clContext.createKernel(PROGRAM_FLUIDS, KERNEL_UPDATE_VEL, { "p_predPos", "p_pos", "", "p_vel" });
  clContext.createKernel(PROGRAM_FLUIDS, KERNEL_UPDATE_POS_BOUNCING, { "p_vel", "p_predPos", "", "p_pos" });
  clContext.createKernel(PROGRAM_FLUIDS, KERNEL_UPDATE_POS_CYCLIC, { "p_vel", "p_predPos", "", "p_pos" });

  return true;
}

void Fluids::updateFluidsParamsInKernel()
{
  CL::Context& clContext = CL::Context::Get();

  float dim = (m_dimension == Dimension::dim2D) ? 2.0f : 3.0f;
  clContext.setKernelArg(KERNEL_RANDOM_POS, 2, sizeof(float), &dim);

  float vel = m_velocity;
  clContext.setKernelArg(KERNEL_UPDATE_VEL, 2, sizeof(float), &vel);

  /*
  std::array<float, 8> boidsParams;
  boidsParams[0] = m_velocity;
  boidsParams[1] = m_activeCohesion ? m_scaleCohesion : 0.0f;
  boidsParams[2] = m_activeAlignment ? m_scaleAlignment : 0.0f;
  boidsParams[3] = m_activeSeparation ? m_scaleSeparation : 0.0f;
  boidsParams[4] = isTargetActivated() ? 1.0f : 0.0f;
  clContext.setKernelArg(KERNEL_BOIDS_RULES_GRID_2D, 3, sizeof(boidsParams), &boidsParams);
  clContext.setKernelArg(KERNEL_BOIDS_RULES_GRID_3D, 3, sizeof(boidsParams), &boidsParams);
 */
}

void Fluids::reset()
{
  if (!m_init)
    return;

  updateFluidsParamsInKernel();

  m_time = clock::now();
  CL::Context& clContext = CL::Context::Get();

  clContext.acquireGLBuffers({ "p_pos", "c_partDetector" });
  clContext.runKernel(KERNEL_INFINITE_POS, m_maxNbParticles);
  clContext.runKernel(KERNEL_RANDOM_POS, m_currNbParticles);
  clContext.runKernel(KERNEL_FLUSH_GRID_DETECTOR, m_nbCells);
  clContext.runKernel(KERNEL_FILL_GRID_DETECTOR, m_currNbParticles);

  clContext.runKernel(KERNEL_RESET_CELL_ID, m_maxNbParticles);
  clContext.runKernel(KERNEL_RESET_CAMERA_DIST, m_maxNbParticles);

  clContext.releaseGLBuffers({ "p_pos", "c_partDetector" });
}

void Fluids::update()
{
  if (!m_init)
    return;

  CL::Context& clContext = CL::Context::Get();

  clContext.acquireGLBuffers({ "p_pos", "c_partDetector", "u_cameraPos" });

  if (!m_pause)
  {
    auto currentTime = clock::now();
    float timeStep = (float)(std::chrono::duration_cast<std::chrono::milliseconds>(currentTime - m_time).count()) / 16.0f;
    // Resetting it if pause mode activated for more than 0.5s
    if (timeStep > 30.0f)
      timeStep = 0.0f;
    m_time = currentTime;

    clContext.runKernel(KERNEL_FILL_CELL_ID, m_currNbParticles);

    m_radixSort.sort("p_cellID", { "p_pos", "p_vel" });

    // Prediction on velocity and correction
    clContext.setKernelArg(KERNEL_PREDICT_POS, 2, sizeof(float), &timeStep);
    clContext.runKernel(KERNEL_PREDICT_POS, m_currNbParticles);

    // NNS
    clContext.runKernel(KERNEL_FLUSH_START_END_CELL, m_nbCells);
    clContext.runKernel(KERNEL_FILL_START_CELL, m_currNbParticles);
    clContext.runKernel(KERNEL_FILL_END_CELL, m_currNbParticles);

    if (m_simplifiedMode)
      clContext.runKernel(KERNEL_ADJUST_END_CELL, m_nbCells);

    // Position Based Fluids
    for (int iter = 0; iter < MAX_NB_JACOBI_ITERS; ++iter)
    {
      // Computing density using SPH method
      clContext.runKernel(KERNEL_DENSITY, m_currNbParticles);

      // Computing constraint factor Lambda
      clContext.runKernel(KERNEL_CONSTRAINT_FACTOR, m_currNbParticles);
      // Computing position correction
      clContext.runKernel(KERNEL_CONSTRAINT_CORRECTION, m_currNbParticles);
      // Correcting predicted position
      clContext.runKernel(KERNEL_CORRECT_POS, m_currNbParticles);
    }

    // Update velocity and position
    clContext.setKernelArg(KERNEL_UPDATE_VEL, 1, sizeof(float), &timeStep);
    clContext.runKernel(KERNEL_UPDATE_VEL, m_currNbParticles);

    switch (m_boundary)
    {
    case Boundary::CyclicWall:
      clContext.setKernelArg(KERNEL_UPDATE_POS_CYCLIC, 1, sizeof(float), &timeStep);
      clContext.runKernel(KERNEL_UPDATE_POS_CYCLIC, m_currNbParticles);
      break;
    case Boundary::BouncingWall:
      clContext.setKernelArg(KERNEL_UPDATE_POS_BOUNCING, 1, sizeof(float), &timeStep);
      clContext.runKernel(KERNEL_UPDATE_POS_BOUNCING, m_currNbParticles);
      break;
    }

    clContext.runKernel(KERNEL_FLUSH_GRID_DETECTOR, m_nbCells);
    clContext.runKernel(KERNEL_FILL_GRID_DETECTOR, m_currNbParticles);
  }

  clContext.runKernel(KERNEL_FILL_CAMERA_DIST, m_currNbParticles);

  m_radixSort.sort("p_cameraDist", { "p_pos", "p_vel" });

  clContext.releaseGLBuffers({ "p_pos", "c_partDetector", "u_cameraPos" });
}

// Position based fluids model based on NVIDIA paper 
// Muller and al. 2013. "Position Based Fluids"

// Preprocessor defines following constant variables in Boids.cpp
// EFFECT_RADIUS           - radius around a particle where boids laws apply 
// ABS_WALL_POS            - absolute position of the walls in x,y,z
// GRID_RES                - resolution of the grid
// GRID_NUM_CELLS          - total number of cells in the grid
// NUM_MAX_PARTS_IN_CELL   - maximum number of particles taking into account in a single cell in simplified mode
// REST_DENSITY            - rest density of the fluid
// POLY6_COEFF             - coefficient of the Poly6 kernel, depending on EFFECT_RADIUS
// SPIKY_COEFF             - coefficient of the Spiky kernel, depending on EFFECT_RADIUS

#define ID            get_global_id(0)
#define GRAVITY_ACC   (float4)(0.0f, -9.81f, 0.0f, 0.0f)
#define FLOAT_EPS     0.00000001f

// Defined in utils.cl
/*
  Random unsigned integer number generator
*/
inline unsigned int parallelRNG(unsigned int i);

// Defined in grid.cl
/*
  Compute 3D index of the cell containing given position
*/
inline int3 getCell3DIndexFromPos(float4 pos);
/*
  Compute 1D index of the cell containing given position
*/
inline uint getCell1DIndexFromPos(float4 pos);

/*
  Poly6 kernel introduced in
  Muller and al. 2003. "Particle-based fluid simulation for interactive applications"
  Return null value if vec length is superior to effectRadius
*/
inline float poly6(const float4 vec, const float effectRadius)
{
  float vecLength = fast_length(vec);
  return (1.0f - step(effectRadius, vecLength)) * POLY6_COEFF * pow((effectRadius * effectRadius - vecLength * vecLength),3);
}

/*
  Jacobian (on vec) of Spiky kernel introduced in
  Muller and al. 2003. "Particle-based fluid simulation for interactive applications"
  Return null vector if vec length is superior to effectRadius
*/
inline float4 gradSpiky(const float4 vec, const float effectRadius)
{
  float vecLength = fast_length(vec);
  return vec * (1.0f - step(effectRadius, vecLength)) * SPIKY_COEFF * -3 * pow((effectRadius - vecLength), 2);
}

/*
  Fill position buffer with random positions
*/
__kernel void randPosVertsFluid(//Output
                                __global float4 *pos, // 0
                                __global float4 *vel, // 1
                                //Param
                                         float  dim)  // 2
{
  const unsigned int randomIntX = parallelRNG(ID);
  const unsigned int randomIntY = parallelRNG(ID + 1);
  const unsigned int randomIntZ = parallelRNG(ID + 2);

  const float x = (float)(randomIntX & 0x0ff) * 2.0 - 250.0f;
  const float y = (float)(randomIntY & 0x0ff) * 2.0 - 250.0f;
  const float z = (float)(randomIntZ & 0x0ff) * 2.0 - 250.0f;

  const float3 randomXYZ = (float3)(x * step(3.0f, dim), y, z);

  pos[ID].xyz = clamp(randomXYZ, -ABS_WALL_POS, ABS_WALL_POS);
  pos[ID].w = 0.0f;

  vel[ID].xyz = (float3)(0.0f, 0.0f, 0.0f);
  vel[ID].w = 0.0f;
}

/*
  Predict fluid particle position and update velocity by integrating external forces
*/
__kernel void predictPosition(//Input
                              const __global float4 *pos,        // 0
                              //Input/Output
                                    __global float4 *vel,        // 1
                              //Param
                              const          float  timeStep,    // 2
                              const          float  maxVelocity, // 3
                              //Output
                                    __global float4 *predPos)    // 4
{
  vel[ID] += maxVelocity * GRAVITY_ACC * timeStep;

  predPos[ID] = pos[ID] + vel[ID] * timeStep;
}

/*
  Compute fluid density based on SPH model
  using predicted position and Poly6 kernel
*/
__kernel void computeDensity(//Input
                              const __global float4 *predPos,      // 0
                              const __global uint2  *startEndCell, // 1
                              //Output
                                    __global float  *density)      // 2
{
  const float4 pos = predPos[ID];
  const uint currCell1DIndex = getCell1DIndexFromPos(pos);
  const int3 currCell3DIndex = getCell3DIndexFromPos(pos);
  const uint2 startEnd = startEndCell[currCell1DIndex];

  float fluidDensity = 0.0f;

  int x = 0;
  int y = 0;
  int z = 0;
  uint  cellIndex = 0;
  uint2 startEndN = (uint2)(0, 0);

  // 27 cells to visit, current one + 3D neighbors
  for (int iX = -1; iX <= 1; ++iX)
  {
    for (int iY = -1; iY <= 1; ++iY)
    {
      for (int iZ = -1; iZ <= 1; ++iZ)
      {
        x = currCell3DIndex.x + iX;
        y = currCell3DIndex.y + iY;
        z = currCell3DIndex.z + iZ;

        if (x < 0 || x >= GRID_RES
         || y < 0 || y >= GRID_RES
         || z < 0 || z >= GRID_RES)
          continue;

        cellIndex = (x * GRID_RES + y) * GRID_RES + z;

        startEndN = startEndCell[cellIndex];

        for (uint e = startEndN.x; e <= startEndN.y; ++e)
        {
          fluidDensity += poly6(pos - predPos[e], (float)EFFECT_RADIUS);
        }
      }
    }
  }

  density[ID] = fluidDensity;
}

/*
  Compute Constraint Factor (Lambda), coefficient along jacobian
*/
__kernel void computeConstraintFactor(//Input
                                      const __global float4 *predPos,       // 1
                                      const __global float  *density,       // 2
                                      const __global float  *startEndCell,  // 3
                                      //Output
                                            __global float  *constFactor)   // 4
{
  const float4 pos = predPos[ID];
  const uint currCell1DIndex = getCell1DIndexFromPos(pos);
  const int3 currCell3DIndex = getCell3DIndexFromPos(pos);
  const uint2 startEnd = startEndCell[currCell1DIndex];

  int x = 0;
  int y = 0;
  int z = 0;
  uint  cellIndex = 0;
  uint2 startEndN = (uint2)(0, 0);

  float4 vec = (float4)(0.0f, 0.0f, 0.0f, 0.0f);

  float4 grad = (float4)(0.0f, 0.0f, 0.0f, 0.0f);
  float4 sumGradCi = (float4)(0.0f, 0.0f, 0.0f, 0.0f);
  float sumSqGradC = 0.0f;

  // 27 cells to visit, current one + 3D neighbors
  for (int iX = -1; iX <= 1; ++iX)
  {
    for (int iY = -1; iY <= 1; ++iY)
    {
      for (int iZ = -1; iZ <= 1; ++iZ)
      {
        x = currCell3DIndex.x + iX;
        y = currCell3DIndex.y + iY;
        z = currCell3DIndex.z + iZ;

        if (x < 0 || x >= GRID_RES
         || y < 0 || y >= GRID_RES
         || z < 0 || z >= GRID_RES)
          continue;

        cellIndex = (x * GRID_RES + y) * GRID_RES + z;

        startEndN = startEndCell[cellIndex];

        for (uint e = startEndN.x; e <= startEndN.y; ++e)
        {
          vec = pos - predPos[e];

          // Supposed to be null if vec = 0.0f;
          grad = gradSpiky(vec, (float)EFFECT_RADIUS);
          // Contribution from the ID particle
          sumGradCi += grad;
          // Contribution from its neighbors
          sumSqGradC += dot(grad, grad);
        }
      }
    }
  }

  sumSqGradC += dot(sumGradCi, sumGradCi);
  sumSqGradC /= REST_DENSITY * REST_DENSITY;

  float densityC = density[ID] / REST_DENSITY - 1.0f;

  constFactor[ID] = - densityC / (sumSqGradC + RELAX_CFM);
}

/*
  Compute Constraint Correction
*/
__kernel void computeConstraintCorrection(//Input
                                          const __global float  *constFactor,  // 0
                                          const __global uint2  *startEndCell, // 1
                                          const __global float4 *predPos,      // 2
                                          //Output
                                                __global float4 *corrPos)      // 3
{
  const float4 pos = predPos[ID];
  const uint currCell1DIndex = getCell1DIndexFromPos(pos);
  const int3 currCell3DIndex = getCell3DIndexFromPos(pos);
  const uint2 startEnd = startEndCell[currCell1DIndex];

  const float lambdaI = constFactor[ID];

  int x = 0;
  int y = 0;
  int z = 0;
  uint  cellIndex = 0;
  uint2 startEndN = (uint2)(0, 0);

  float4 vec = (float4)(0.0f, 0.0f, 0.0f, 0.0f);
  float4 corr = (float4)(0.0f, 0.0f, 0.0f, 0.0f);

  // 27 cells to visit, current one + 3D neighbors
  for (int iX = -1; iX <= 1; ++iX)
  {
    for (int iY = -1; iY <= 1; ++iY)
    {
      for (int iZ = -1; iZ <= 1; ++iZ)
      {
        x = currCell3DIndex.x + iX;
        y = currCell3DIndex.y + iY;
        z = currCell3DIndex.z + iZ;

        if (x < 0 || x >= GRID_RES
         || y < 0 || y >= GRID_RES
         || z < 0 || z >= GRID_RES)
          continue;

        cellIndex = (x * GRID_RES + y) * GRID_RES + z;

        startEndN = startEndCell[cellIndex];

        for (uint e = startEndN.x; e <= startEndN.y; ++e)
        {
          vec = pos - predPos[e];

          corr += (lambdaI + constFactor[e]) * gradSpiky(vec, EFFECT_RADIUS);
        }
      }
    }
  }

  corrPos[ID] = corr / REST_DENSITY;
}

/*
  Correction position using Constraint correction value
*/
__kernel void correctPosition(//Input
                              const __global float4 *corrPos, // 0
                              //Input/Output
                                    __global float4 *predPos) // 2
{
  predPos[ID] += corrPos[ID];
}

/*
  Update velocity buffer.
*/
__kernel void updateVel(//Input
                        const __global float4 *predPos,    // 0
                        const __global float4 *pos,        // 1
                        //Param
                        const          float  timeStep,    // 2
                        //Output
                              __global float4 *vel)        // 3
   
{
  // Preventing division by 0
  vel[ID] = (predPos[ID] - pos[ID]) / (timeStep + FLOAT_EPS);
}

/*
  Apply Bouncing wall boundary conditions on position and velocity buffers.
*/
__kernel void updatePosWithBouncingWalls(//Input
                                         const  __global float4 *predPos, // 0
                                         //Output
                                                __global float4 *pos)     // 1

{
  pos[ID] = clamp(predPos[ID], -ABS_WALL_POS, ABS_WALL_POS);
}
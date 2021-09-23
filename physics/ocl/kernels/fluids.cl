
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

// See FluidKernelInputs in Fluids.cpp
typedef struct defFluidParams{
  float effectRadius;
  float restDensity;
  float relaxCFM;
  float timeStep;
  uint  dim;
} FluidParams;


// Defined in utils.cl
/*
  Random unsigned integer number generator
*/
inline unsigned int parallelRNG(unsigned int i);

// Defined in grid.cl
/*
  Compute 3D index of the cell containing given position
*/
inline uint3 getCell3DIndexFromPos(float4 pos);
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
  return (1.0f - step(effectRadius, vecLength)) * POLY6_COEFF * pow((effectRadius * effectRadius - vecLength * vecLength), 3);
}

/*
  Jacobian (on vec coords) of Spiky kernel introduced in
  Muller and al. 2003. "Particle-based fluid simulation for interactive applications"
  Return null vector if vec length is superior to effectRadius
*/
inline float4 gradSpiky(const float4 vec, const float effectRadius)
{
  const float vecLength = fast_length(vec);

  if(vecLength <= FLOAT_EPS)
    return (float4)(0.0f);

  return vec * (1.0f - step(effectRadius, vecLength)) * SPIKY_COEFF * -3 * pow((effectRadius - vecLength), 2) / vecLength;
}

/*
  Fill position buffer with random positions
*/
__kernel void randPosVertsFluid(//Param
                                const FluidParams fluid, // 0
                                //Output
                                __global   float4 *pos,  // 1
                                __global   float4 *vel)  // 2
                                
{
  const unsigned int randomIntX = parallelRNG(ID);
  const unsigned int randomIntY = parallelRNG(ID + 1);
  const unsigned int randomIntZ = parallelRNG(ID + 2);

  const float x = (float)(randomIntX & 0x0ff) * 2.0 - ABS_WALL_POS;
  const float y = (float)(randomIntY & 0x0ff) * 2.0 - ABS_WALL_POS;
  const float z = (float)(randomIntZ & 0x0ff) * 2.0 - ABS_WALL_POS;

  const float3 randomXYZ = (float3)(x * convert_float(3 - fluid.dim), y, z);

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
                              const __global float4 *vel,        // 1
                              //Param
                              const     FluidParams fluid,       // 2
                              const          float  maxVelocity, // 3
                              //Output
                                    __global float4 *predPos)    // 4
{
  // No need to update global vel, as it will be reset later on
  const float4 newVel = vel[ID] + GRAVITY_ACC * maxVelocity * fluid.timeStep;

  predPos[ID] = pos[ID] + newVel * fluid.timeStep;
}

/*
  Compute fluid density based on SPH model
  using predicted position and Poly6 kernel
*/
__kernel void computeDensity(//Input
                              const __global float4 *predPos,      // 0
                              const __global uint2  *startEndCell, // 1
                              //Param
                              const     FluidParams fluid,         // 2
                              //Output
                                    __global float  *density)      // 3
{
  const float4 pos = predPos[ID];
  const uint currCell1DIndex = getCell1DIndexFromPos(pos);
  const uint3 currCell3DIndex = getCell3DIndexFromPos(pos);

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
        x = convert_int(currCell3DIndex.x) + iX;
        y = convert_int(currCell3DIndex.y) + iY;
        z = convert_int(currCell3DIndex.z) + iZ;

        if (x < 0 || x >= GRID_RES
         || y < 0 || y >= GRID_RES
         || z < 0 || z >= GRID_RES)
          continue;

        cellIndex = (x * GRID_RES + y) * GRID_RES + z;

        startEndN = startEndCell[cellIndex];

        for (uint e = startEndN.x; e <= startEndN.y; ++e)
        {
          fluidDensity += poly6(pos - predPos[e], fluid.effectRadius);
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
                                      const __global float4 *predPos,       // 0
                                      const __global float  *density,       // 1
                                      const __global uint2  *startEndCell,  // 2
                                      //Param
                                      const     FluidParams fluid,          // 3
                                      //Output
                                            __global float  *constFactor)   // 4
{
  const float4 pos = predPos[ID];
  const uint3 currCell3DIndex = getCell3DIndexFromPos(pos);
  const float currDensityC = density[ID] / fluid.restDensity - 1.0f;

  int x = 0;
  int y = 0;
  int z = 0;
  uint  cellIndexN = 0;
  uint2 startEndN = (uint2)(0);

  float4 vec = (float4)(0.0f);

  float4 grad = (float4)(0.0f);
  float4 sumGradCi = (float4)(0.0f);
  float sumSqGradC = 0.0f;

  // 27 cells to visit, current one + 3D neighbors
  for (int iX = -1; iX <= 1; ++iX)
  {
    for (int iY = -1; iY <= 1; ++iY)
    {
      for (int iZ = -1; iZ <= 1; ++iZ)
      {
        x = convert_int(currCell3DIndex.x) + iX;
        y = convert_int(currCell3DIndex.y) + iY;
        z = convert_int(currCell3DIndex.z) + iZ;

        if (x < 0 || x >= GRID_RES
         || y < 0 || y >= GRID_RES
         || z < 0 || z >= GRID_RES)
          continue;

        cellIndexN = (x * GRID_RES + y) * GRID_RES + z;

        startEndN = startEndCell[cellIndexN];

        for (uint e = startEndN.x; e <= startEndN.y; ++e)
        {
          vec = pos - predPos[e];

          // Supposed to be null if vec = 0.0f;
          grad = gradSpiky(vec, fluid.effectRadius);
          // Contribution from the ID particle
          sumGradCi += grad;
          // Contribution from its neighbors
          sumSqGradC += dot(grad, grad);
        }
      }
    }
  }

  sumSqGradC += dot(sumGradCi, sumGradCi);
  sumSqGradC /= fluid.restDensity * fluid.restDensity;

  constFactor[ID] = - currDensityC / (sumSqGradC + fluid.relaxCFM);
}

/*
  Compute Constraint Correction
*/
__kernel void computeConstraintCorrection(//Input
                                          const __global float  *constFactor,  // 0
                                          const __global uint2  *startEndCell, // 1
                                          const __global float4 *predPos,      // 2
                                          //Param
                                          const     FluidParams fluid,         // 3
                                          //Output
                                                __global float4 *corrPos)      // 4
{
  const float4 pos = predPos[ID];
  const uint3 currCell3DIndex = getCell3DIndexFromPos(pos);
  const float lambdaI = constFactor[ID];

  int x = 0;
  int y = 0;
  int z = 0;
  uint  cellIndexN = 0;
  uint2 startEndN = (uint2)(0);

  float4 vec = (float4)(0.0f);
  float4 corr = (float4)(0.0f);

  // 27 cells to visit, current one + 3D neighbors
  for (int iX = -1; iX <= 1; ++iX)
  {
    for (int iY = -1; iY <= 1; ++iY)
    {
      for (int iZ = -1; iZ <= 1; ++iZ)
      {
        x = convert_int(currCell3DIndex.x) + iX;
        y = convert_int(currCell3DIndex.y) + iY;
        z = convert_int(currCell3DIndex.z) + iZ;

        if (x < 0 || x >= GRID_RES
         || y < 0 || y >= GRID_RES
         || z < 0 || z >= GRID_RES)
          continue;

        cellIndexN = (x * GRID_RES + y) * GRID_RES + z;

        startEndN = startEndCell[cellIndexN];

        for (uint e = startEndN.x; e <= startEndN.y; ++e)
        {
          vec = pos - predPos[e];

          corr += (lambdaI + constFactor[e]) * gradSpiky(vec, fluid.effectRadius);
        }
      }
    }
  }

  corrPos[ID] = corr / fluid.restDensity;
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
                        const     FluidParams fluid,    // 2
                        //Output
                              __global float4 *vel)        // 3
   
{
  // Preventing division by 0
  vel[ID] = (predPos[ID] - pos[ID]) / (fluid.timeStep + FLOAT_EPS);
}

/*
  Apply Bouncing wall boundary conditions on position.
*/
__kernel void updatePosWithBouncingWalls(//Input
                                         const  __global float4 *predPos, // 0
                                         //Output
                                                __global float4 *pos)     // 1
{
  pos[ID] = clamp(predPos[ID], -ABS_WALL_POS, ABS_WALL_POS);
}

/*
  Apply Bouncing wall boundary conditions on position
*/
__kernel void applyBoundaryCondition(__global float4 *predPos)
{
  predPos[ID] = clamp(predPos[ID], -ABS_WALL_POS, ABS_WALL_POS);
}

/*
  Update position using predicted one
*/
__kernel void updatePosition(//Input
                              const  __global float4 *predPos, // 0
                              //Output
                                     __global float4 *pos)     // 1
{
  pos[ID] = clamp(predPos[ID], -ABS_WALL_POS, ABS_WALL_POS);
}

/*
  Fill fluid color buffer with constraint value for real-time analysis
  R = 1 by default
  G = 0 => constraint = 0, i.e density is close from rest density
  G > 0 => constraint > 0, i.e density is either bigger or smaller than rest density

  Reddish particles means the system has found an equilibrium
  Yellowish (R + G) means the density is either too high or too low and the system is not stabilized
*/
__kernel void fillFluidColor(//Input
                             const  __global float  *density, // 0
                             //Param
                             const      FluidParams fluid,    // 1
                             //Output
                                    __global float4 *col)     // 2
{
  float constraint = fabs(1.0f - density[ID] / fluid.restDensity);
  col[ID] = (float4)(1.0f, constraint, 0.0f, 1.0f);
}
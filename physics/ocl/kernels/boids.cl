// Preprocessor defines following constant variables in Boids.cpp
// EFFECT_RADIUS_SQUARED   - squared radius around a particle where boids laws apply 
// ABS_WALL_X            - absolute position of the walls in x,y,z
// GRID_RES_X                - resolution of the grid
// GRID_NUM_CELLS          - total number of cells in the grid
// NUM_MAX_PARTS_IN_CELL   - maximum number of particles taking into account in a single cell in simplified mode

// Most defines are in define.cl
// define.cl must be included as the first .cl file to create the OpenCL program 
#define MAX_STEERING  0.5f

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
  Fill color buffer with chosen color, could be a physics variable for real-time analysis
*/
__kernel void bd_fillBoidsColor(__global float4 *col)
{
  col[ID] = (float4)(1.0f, 0.02f, 0.02f, 1.0f);
}

/*
  Apply 3 boids rules using grid in 3D.
*/
__kernel void bd_applyBoidsRulesWithGrid3D(//Input
                                           const __global float4 *position,     // 0
                                           const __global float4 *velocity,     // 1
                                           const __global uint2  *startEndCell, // 2
                                           //Param
                                           const          float8 params,        // 3
                                           //Output
                                                 __global float4 *acc)          // 4
{
  const float4 pos = position[ID];
  const float4 vel = velocity[ID];

  const uint currCellIndex1D = getCell1DIndexFromPos(pos);
  const uint3 currCellIndex3D = getCell3DIndexFromPos(pos);
  const uint2 startEnd = startEndCell[currCellIndex1D];

  int count = 0;

  float4 newAcc = (float4)(0.0f);
  float4 averageBoidsPos = (float4)(0.0f);
  float4 averageBoidsVel = (float4)(0.0f);
  float4 repulseHeading  = (float4)(0.0f);

  float squaredDist = 0.0f;
  float4 vec = (float4)(0.0f);

  uint cellNIndex1D = 0;
  int3 cellNIndex3D = (int3)(0);
  uint2 startEndN = (uint2)(0);
  float4 posN = (float4)(0.0f);

  // 27 cells to visit, current one + 3D neighbors
  for (int iX = -1; iX <= 1; ++iX)
  {
    for (int iY = -1; iY <= 1; ++iY)
    {
      for (int iZ = -1; iZ <= 1; ++iZ)
      {
        cellNIndex3D = convert_int3(currCellIndex3D) + (int3)(iX, iY, iZ);
        
        // Removing out of range cells
        if(any(cellNIndex3D < (int3)(0)) || any(cellNIndex3D >= (int3)(GRID_RES_X, GRID_RES_Y, GRID_RES_Z)))
          continue;

        cellNIndex1D = (cellNIndex3D.x * GRID_RES_Y + cellNIndex3D.y) * GRID_RES_Z + cellNIndex3D.z;

        startEndN = startEndCell[cellNIndex1D];

        for (uint e = startEndN.x; e <= startEndN.y; ++e)
        {
          posN = position[e];

          vec = pos - posN;
          squaredDist = dot(vec, vec);

          // Second condition to deal with almost identical points and i == e
          if (squaredDist < EFFECT_RADIUS_SQUARED
           && squaredDist > FLOAT_EPS)
          {
            averageBoidsPos += posN;
            averageBoidsVel += fast_normalize(velocity[e]);
            repulseHeading  += vec / squaredDist;
            ++count;
          }
        }
      }
    }
  }

  // params 0 = vel - 1 = cohesion - 2 = alignement - 3 = separation - 4 = target
  if (count != 0)
  {
    // cohesion
    averageBoidsPos /= count;
    averageBoidsPos -= pos;
    averageBoidsPos  = fast_normalize(averageBoidsPos) * params.s0;
    // alignment
    averageBoidsVel  = fast_normalize(averageBoidsVel) * params.s0;
    // separation
    repulseHeading   = fast_normalize(repulseHeading)  * params.s0;

    newAcc = averageBoidsPos * params.s1
           + averageBoidsVel * params.s2
           + repulseHeading  * params.s3;
  }

  acc[ID] = newAcc;
}

/*
  Apply 3 boids rules using grid in 2D.
*/
__kernel void bd_applyBoidsRulesWithGrid2D(//Input
                                           const __global float4 *position,     // 0
                                           const __global float4 *velocity,     // 1
                                           const __global uint2  *startEndCell, // 2
                                           //Param
                                           const          float8 params,        // 3
                                           //Output
                                                 __global float4 *acc)          // 4

{
  const float4 pos = position[ID];
  const float4 vel = velocity[ID];

  const uint currCellIndex1D = getCell1DIndexFromPos(pos);
  const uint3 currCellIndex3D = getCell3DIndexFromPos(pos);
  const uint2 startEnd = startEndCell[currCellIndex1D];

  int count = 0;

  float4 newAcc = (float4)(0.0f);
  float4 averageBoidsPos = (float4)(0.0f);
  float4 averageBoidsVel = (float4)(0.0f);
  float4 repulseHeading  = (float4)(0.0f);

  float squaredDist = 0.0f;
  float4 vec = (float4)(0.0f);

  uint cellNIndex1D = 0;
  int3 cellNIndex3D = (int3)(0);
  uint2 startEndN = (uint2)(0);
  float4 posN = (float4)(0.0f);

  // 9 cells to visit, current one + 2D YZ neighbors
  for (int iY = -1; iY <= 1; ++iY)
  {
    for (int iZ = -1; iZ <= 1; ++iZ)
    {
      cellNIndex3D = convert_int3(currCellIndex3D) + (int3)(0, iY, iZ);
      
      // Removing out of range cells
      if(any(cellNIndex3D < (int3)(0)) || any(cellNIndex3D >= (int3)(GRID_RES_X)))
        continue;

      cellNIndex1D = (GRID_RES_X / 2 * GRID_RES_X + cellNIndex3D.y) * GRID_RES_Y + cellNIndex3D.z;

      startEndN = startEndCell[cellNIndex1D];

      for (uint e = startEndN.x; e <= startEndN.y; ++e)
      {
        posN = position[e];

        vec = pos - posN;
        squaredDist = dot(vec, vec);

        // Second condition to deal with almost identical points and i == e
        if (squaredDist < EFFECT_RADIUS_SQUARED
         && squaredDist > FLOAT_EPS)
        {
          averageBoidsPos += posN;
          averageBoidsVel += fast_normalize(velocity[e]);
          repulseHeading += vec / squaredDist;
          ++count;
        }
      }
    }
  }

  // params 0 = vel - 1 = cohesion - 2 = alignement - 3 = separation - 4 = target
  if (count != 0)
  {
    // cohesion
    averageBoidsPos /= count;
    averageBoidsPos -= pos;
    averageBoidsPos  = fast_normalize(averageBoidsPos) * params.s0;
    // alignment
    averageBoidsVel  = fast_normalize(averageBoidsVel) * params.s0;
    // separation
    repulseHeading   = fast_normalize(repulseHeading)  * params.s0;

    newAcc = averageBoidsPos * params.s1
           + averageBoidsVel * params.s2
           + repulseHeading  * params.s3;
  }

  acc[ID] = newAcc;
}

/*
  Add target rule.
*/
__kernel void bd_addTargetRule(//Input
                               const __global float4 *pos,                      // 0
                               //Param
                               const          float4 targetPos,                 // 1
                               const          float  targetSquaredRadiusEffect, // 2
                               const          int    targetSignEffect,          // 3
                               //Output
                                     __global float4 *acc)                      // 4
        
{
  const float4 currPos = pos[ID];

  const float4 vec = targetPos - currPos;
  const float  dist = fast_length(vec);

  if (dist < half_sqrt(targetSquaredRadiusEffect))
    acc[ID] += targetSignEffect * vec * clamp(1.3f / dist, 0.0f, 1.4f * MAX_STEERING);
}

/*
  Update velocity buffer.
*/
__kernel void bd_updateVel(//Input
                           const __global float4 *acc,        // 0
                           //Param
                           const          float  timeStep,    // 1
                           const          float  maxVelocity, // 2
                           //Output
                                 __global float4 *vel)        // 3
   
{
  const float4 newVel = vel[ID] + acc[ID] * timeStep;
  const float  newVelNorm = clamp(fast_length(newVel), 0.2f * maxVelocity, maxVelocity);
  
  vel[ID] = fast_normalize(newVel) * newVelNorm;
}

/*
  Apply Bouncing wall boundary conditions on position and velocity buffers.
*/
__kernel void bd_updatePosWithBouncingWalls(//Input/output
                                                  __global float4 *vel,     // 0
                                            //Param
                                            const          float  timeStep, // 1
                                            //Input/output
                                                  __global float4 *pos)     // 2

{
  const float4 newPos = pos[ID] + vel[ID] * timeStep;

  const float4 clampedNewPos = clamp(newPos, (float4)(-ABS_WALL_X, -ABS_WALL_Y, -ABS_WALL_Z, 0.0f),
                                             (float4)( ABS_WALL_X,  ABS_WALL_Y,  ABS_WALL_Z, 0.0f));
  
  pos[ID] = clampedNewPos;

  if (!all(isequal(clampedNewPos.xyz, newPos.xyz)))
  {
    vel[ID] *= -0.5f;
  }
}

/*
  Apply Cyclic wall boundary conditions on position and velocity buffers.
*/
__kernel void bd_updatePosWithCyclicWalls(//Input
                                          const __global float4 *vel,     // 0
                                          //Param
                                          const          float  timeStep, // 1
                                          //Input/output
                                                __global float4 *pos)     // 2
{
  const float4 newPos = pos[ID] + vel[ID] * timeStep;

  float4 clampedNewPos = clamp(newPos, (float4)(-ABS_WALL_X, -ABS_WALL_Y, -ABS_WALL_Z, 0.0f),
                                       (float4)( ABS_WALL_X,  ABS_WALL_Y,  ABS_WALL_Z, 0.0f));
 
  if (!isequal(clampedNewPos.x, newPos.x))
  {
    clampedNewPos.x *= -1.0f;
  }
  if (!isequal(clampedNewPos.y, newPos.y))
  {
    clampedNewPos.y *= -1.0f;
  }
  if (!isequal(clampedNewPos.z, newPos.z))
  {
    clampedNewPos.z *= -1.0f;
  }

  pos[ID] = clampedNewPos;
}

//
//
//
//
// Classic boids physics with no grid, O(N^2) in time complexity
/*
inline float4 steerForce(float4 desiredVel, float4 vel)
{
  float4 steerForce = desiredVel - vel;
  if (length(steerForce) > MAX_STEERING)
  {
    steerForce = fast_normalize(steerForce) * MAX_STEERING;
  }
  return steerForce;
}

__kernel void applyBoidsRules(__global float4* position, __global float4* velocity, __global float4* acc, __global boidsParams* params)
{
  unsigned int i = get_global_id(0);
  unsigned int numEnt = get_global_size(0);

  float4 pos = position[i];
  float4 vel = velocity[i];

  int count = 0;

  float4 averageBoidsPos = (float4)(0.0, 0.0, 0.0, 0.0);
  float4 averageBoidsVel = (float4)(0.0, 0.0, 0.0, 0.0);
  float4 repulseHeading = (float4)(0.0, 0.0, 0.0, 0.0);

  float squaredDist = 0.0f;
  float4 vec = (float4)(0.0f, 0.0f, 0.0f, 0.0f);
  for (int e = 0; e < numEnt; ++e)
  {
    vec = pos - position[e];
    squaredDist = dot(vec, vec);

    // Second condition to deal with almost identical points and i == e
    if (squaredDist < EFFECT_RADIUS_SQUARED && squaredDist > FLOAT_EPS)
    {
      averageBoidsPos += position[e];
      averageBoidsVel += velocity[e];
      repulseHeading += vec / squaredDist;
      ++count;
    }
  }

  if (count != 0)
  {
    // cohesion
    averageBoidsPos /= count;
    averageBoidsPos -= pos;
    averageBoidsPos = normalize(averageBoidsPos) * params->velocity;
    // alignment
    averageBoidsVel = normalize(averageBoidsVel) * params->velocity;
    // separation
    repulseHeading = normalize(repulseHeading) * params->velocity;
  }

  float4 target = -pos;

  acc[i] = steerForce(averageBoidsPos, vel) * params->scaleCohesion
      + steerForce(averageBoidsVel, vel) * params->scaleAlignment
      + steerForce(repulseHeading, vel) * params->scaleSeparation
      + clamp(target, 0.0, normalize(target) * MAX_STEERING) * params->activeTarget;

  // Dealing with numerical error, forcing 2D
  if (params->dims < 3.0f)
    acc[i].x = 0.0f;
}
*/

// Implementation of the boids with grid using a texture to store first n pos in each cell
// Big approximation as we only keep the n first ones and, worse, slower than simply using classic global memory!
/*
__kernel void fillBoidsTexture(
    __global uint2* startEndCell,
    __global float4* inputBoidsBuffer,
    __write_only image2d_t outputBoidsText)
{
  int iG = get_group_id(0);
  int iL = get_local_id(0);

  uint2 startEndCellIndex = startEndCell[iG];
  uint nbPartInCell = startEndCellIndex.y - startEndCellIndex.x;

  float4 inPart = (float4)(0.0, 0.0, 0.0, -1.0);

  if (startEndCellIndex.y >= startEndCellIndex.x && iL < nbPartInCell)
    inPart = inputBoidsBuffer[startEndCellIndex.x + iL];

  int2 coords = (int2)(iL, iG);
  write_imagef(outputBoidsText, coords, inPart);
}

__kernel void applyBoidsRulesWithGridAndTex(
    __global float4* position,
    __global float4* velocity,
    __read_only image2d_t posTex,
    __read_only image2d_t velTex,
    __global float4* acc,
    __global uint2* startEndCell,
    float8 params)
{
  unsigned int i = get_global_id(0);

  float4 pos = position[i];
  float4 vel = velocity[i];

  uint cell1DIndex = getCell1DIndexFromPos(pos);

  uint2 startEnd = startEndCell[cell1DIndex];

  if ((startEnd.y - startEnd.x) <= 20 * NUM_MAX_PARTS_IN_CELL)
    return;

  int count = 0;

  float4 averageBoidsPos = (float4)(0.0, 0.0, 0.0, 0.0);
  float4 averageBoidsVel = (float4)(0.0, 0.0, 0.0, 0.0);
  float4 repulseHeading = (float4)(0.0, 0.0, 0.0, 0.0);

  float squaredDist = 0.0f;
  float4 vec = (float4)(0.0f, 0.0f, 0.0f, 0.0f);

  int x = 0;
  int y = 0;
  int z = 0;
  uint3 currentCell3DIndex = getCell3DIndexFromPos(pos);
  uint cellIndex = 0;

  sampler_t samp = CLK_NORMALIZED_COORDS_FALSE | CLK_ADDRESS_NONE | CLK_FILTER_NEAREST;

  float4 posN = (float4)(0.0, 0.0, 0.0, 0.0);

  // 27 cells to visit, current one + 3D neighbors
  for (int iX = -1; iX <= 1; ++iX)
  {
    for (int iY = -1; iY <= 1; ++iY)
    {
      for (int iZ = -1; iZ <= 1; ++iZ)
      {
        x = currentCell3DIndex.x + iX;
        y = currentCell3DIndex.y + iY;
        z = currentCell3DIndex.z + iZ;

        if (x < 0 || x >= GRID_RES_X
            || y < 0 || y >= GRID_RES_X
            || z < 0 || z >= GRID_RES_X)
          return;

        cellIndex = (x * GRID_RES_X + y) * GRID_RES_X + z;

        for (uint partIndex = 0; partIndex < NUM_MAX_PARTS_IN_CELL; ++partIndex)
        {
          posN = read_imagef(posTex, samp, (int2)(partIndex, cellIndex));

          if (isequal(posN.s3, -1.0f))
            continue;

          vec = pos - posN;
          squaredDist = dot(vec, vec);

          // Second condition to deal with almost identical points and i == e
          if (squaredDist < EFFECT_RADIUS_SQUARED && squaredDist > FLOAT_EPS)
          {
            averageBoidsPos += posN;
            averageBoidsVel += read_imagef(velTex, samp, (int2)(partIndex, cellIndex));
            repulseHeading += vec / squaredDist;
            ++count;
          }
        }
      }
    }
  }

  // params 0 = vel - 1 = cohesion - 2 = alignement - 3 = separation - 4 = target
  if (count != 0)
  {
    // cohesion
    averageBoidsPos /= count;
    averageBoidsPos -= pos;
    averageBoidsPos = normalize(averageBoidsPos) * params.s0;
    // alignment
    averageBoidsVel = normalize(averageBoidsVel) * params.s0;
    // separation
    repulseHeading = normalize(repulseHeading) * params.s0;
  }

  float4 target = -pos;

  acc[i] = steerForce(averageBoidsPos, vel) * params.s1
      + steerForce(averageBoidsVel, vel) * params.s2
      + steerForce(repulseHeading, vel) * params.s3
      + clamp(target, 0.0, normalize(target) * MAX_STEERING) * params.s4;
}

// Tentative to use local/shared memory with boids with grid and texture
// Too demanding on local/shared memory side, as we need to store vel and pos for n pos for 27 cells 
// (float4 * 2 * n * 27), cannot get more than n = 50 with gtx1650...

__kernel void applyBoidsRulesWithGridAndTexLocal(
    __global uint2* startEndCell,
    __read_only image2d_t posTex,
    __read_only image2d_t velTex,
    __global float4* acc,
    float8 params,
    __local float4* localPos,
    __local float4* localVel)
{
  unsigned int cellIndex = get_group_id(0);
  unsigned int localPartIndex = get_local_id(0);

  uint2 startEnd = startEndCell[cellIndex];
  uint nbPartInCell = startEnd.y - startEnd.x;

  if (startEnd.y < startEnd.x)
    return;

  sampler_t samp = CLK_NORMALIZED_COORDS_FALSE | CLK_ADDRESS_NONE | CLK_FILTER_NEAREST;

  float4 posF = read_imagef(posTex, samp, (int2)(0, cellIndex));
  uint3 cell3DIndex = getCell3DIndexFromPos(posF);

  // local filling for the 27 cells

  int x = 0;
  int y = 0;
  int z = 0;
  uint cellIndexN = 0;
  uint localIndexCellN = 0;
  float4 posN = (float4)(0.0, 0.0, 0.0, -1.0);
  float4 velN = (float4)(0.0, 0.0, 0.0, -1.0);

  for (int iX = -1; iX <= 1; ++iX)
  {
    for (int iY = -1; iY <= 1; ++iY)
    {
      for (int iZ = -1; iZ <= 1; ++iZ)
      {
        x = cell3DIndex.x + iX;
        y = cell3DIndex.y + iY;
        z = cell3DIndex.z + iZ;

        posN = (float4)(0.0, 0.0, 0.0, -1.0);
        velN = (float4)(0.0, 0.0, 0.0, -1.0);

        if (x >= 0 && x < GRID_RES_X
            && y >= 0 && y < GRID_RES_X
            && z >= 0 && z < GRID_RES_X)
        {
          cellIndexN = (x * GRID_RES_X + y) * GRID_RES_X + z;
          posN = read_imagef(posTex, samp, (int2)(localPartIndex, cellIndexN));
          velN = read_imagef(velTex, samp, (int2)(localPartIndex, cellIndexN));
        }
        localPos[localIndexCellN * NUM_MAX_PARTS_IN_CELL + localPartIndex] = posN;
        localVel[localIndexCellN * NUM_MAX_PARTS_IN_CELL + localPartIndex] = velN;

        ++localIndexCellN;
      }
    }
  }

  barrier(CLK_LOCAL_MEM_FENCE);

  float4 pos = read_imagef(posTex, samp, (int2)(localPartIndex, cellIndex));
  float4 vel = read_imagef(velTex, samp, (int2)(localPartIndex, cellIndex));

  // Not a real part
  if (isequal(pos.w, (float)(-1.0)))
    return;

  float4 averageBoidsPos = (float4)(0.0, 0.0, 0.0, 0.0);
  float4 averageBoidsVel = (float4)(0.0, 0.0, 0.0, 0.0);
  float4 repulseHeading = (float4)(0.0, 0.0, 0.0, 0.0);
  int count = 0;

  float4 localPosN = (float4)(0.0, 0.0, 0.0, 0.0);
  float4 localVelN = (float4)(0.0, 0.0, 0.0, 0.0);
  float4 vec = (float4)(0.0f, 0.0f, 0.0f, 0.0f);
  float squaredDist = 0.0f;

  //size_t numLocalParts = 27 * NUM_MAX_PARTS_IN_CELL;
  size_t numLocalParts = 9 * NUM_MAX_PARTS_IN_CELL;
  for (uint i = 0; i < numLocalParts; ++i)
  {
    localPosN = localPos[i];
    localVelN = localVel[i];

    // Not a real neighbor
    if (isequal(localPosN.w, (float)(-1.0)))
      continue;

    vec = pos - localPosN;
    squaredDist = dot(vec, vec);

    // Second condition to deal with almost identical points
    if (squaredDist < EFFECT_RADIUS_SQUARED && squaredDist > FLOAT_EPS)
    {
      averageBoidsPos += localPosN;
      averageBoidsVel += localVelN;
      repulseHeading += vec / squaredDist;
      ++count;
    }
  }

  // params 0 = vel - 1 = cohesion - 2 = alignement - 3 = separation - 4 = target
  if (count != 0)
  {
    // cohesion
    averageBoidsPos /= count;
    averageBoidsPos -= pos;
    averageBoidsPos = normalize(averageBoidsPos) * params.s0;
    // alignment
    averageBoidsVel = normalize(averageBoidsVel) * params.s0;
    // separation
    repulseHeading = normalize(repulseHeading) * params.s0;
  }

  float4 target = -pos;

  acc[startEnd.x + localPartIndex] = steerForce(averageBoidsPos, vel) * params.s1
      + steerForce(averageBoidsVel, vel) * params.s2
      + steerForce(repulseHeading, vel) * params.s3
      + clamp(target, 0.0, normalize(target) * MAX_STEERING) * params.s4;
}
*/
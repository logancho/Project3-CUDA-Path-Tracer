#include "interactions.h"

__device__ bool Refract(const glm::vec3& wi, const glm::vec3& n, float eta, glm::vec3& w_r) {
    // Compute cos theta using Snell's law
    float cosThetaI = dot(n, wi);
    float sin2ThetaI = glm::max(float(0), float(1 - cosThetaI * cosThetaI));
    float sin2ThetaT = eta * eta * sin2ThetaI;

    // Handle total internal reflection for transmission
    if (sin2ThetaT >= 1) return false;
    float cosThetaT = sqrt(1 - sin2ThetaT);
    w_r = eta * -wi + (eta * cosThetaI - cosThetaT) * n;
    return true;
}

__device__ void squareToDiskConcentric(const glm::vec2 xi, glm::vec3& wi)
{
    //Remap to [-1, 1], [-1, 1]
    glm::vec2 offset = 2.f * xi - glm::vec2(1, 1);
    if (offset.x == 0 && offset.y == 0)
    {
        //Handle base case
        wi = glm::vec3(0);
    }

    // Apply concentric mapping to point
    float theta, r;
    if (abs(offset.x) > abs(offset.y)) {
        r = offset.x;
        theta = PI_OVER_FOUR * (offset.y / offset.x);
    }
    else {
        r = offset.y;
        theta = PI_OVER_TWO - PI_OVER_FOUR * (offset.x / offset.y);
    }
    wi = r * glm::vec3(cos(theta), sin(theta), 0);
}

__device__ void squareToHemisphereCosine(const glm::vec2 xi, glm::vec3 &wi) {
    squareToDiskConcentric(xi, wi);
    //Extrapolate z using x, y coords of the point, uniformly sampled at the base of the hemisphere!
    float z = sqrt(glm::max(0.f, 1.f - wi.x * wi.x - wi.y * wi.y));
    wi.z = z;
}

__host__ __device__ glm::vec3 calculateRandomDirectionInHemisphere(
    glm::vec3 normal,
    thrust::default_random_engine &rng)
{
    thrust::uniform_real_distribution<float> u01(0, 1);

    float up = sqrt(u01(rng)); // cos(theta)
    float over = sqrt(1 - up * up); // sin(theta)
    float around = u01(rng) * TWO_PI;

    // Find a direction that is not the normal based off of whether or not the
    // normal's components are all equal to sqrt(1/3) or whether or not at
    // least one component is less than sqrt(1/3). Learned this trick from
    // Peter Kutz.

    glm::vec3 directionNotNormal;
    if (abs(normal.x) < SQRT_OF_ONE_THIRD)
    {
        directionNotNormal = glm::vec3(1, 0, 0);
    }
    else if (abs(normal.y) < SQRT_OF_ONE_THIRD)
    {
        directionNotNormal = glm::vec3(0, 1, 0);
    }
    else
    {
        directionNotNormal = glm::vec3(0, 0, 1);
    }

    // Use not-normal direction to generate two perpendicular directions
    glm::vec3 perpendicularDirection1 =
        glm::normalize(glm::cross(normal, directionNotNormal));
    glm::vec3 perpendicularDirection2 =
        glm::normalize(glm::cross(normal, perpendicularDirection1));

    return up * normal
        + cos(around) * over * perpendicularDirection1
        + sin(around) * over * perpendicularDirection2;
}

/**
* The function FrDielectric() computes the Fresnel reflection formula for dielectric materials and unpolarized light.
* REMEMBER: Reflection != Refraction!
**/
__device__ float FresnelDielectricEval(float cI)
{
    float etai = 1.;
    float etat = 1.55;
    float cosThetaI = glm::clamp(cI, -1.f, 1.f);

    // Potentially swap 
    bool entering = cosThetaI > 0.f;
    if (!entering) {
        float temp = etai;
        etai = etat;
        etat = temp;
        cosThetaI = abs(cosThetaI);
    }

    // Snells Law
    float eta = etai / etat;
    float sint = eta * sqrtf(glm::max(0.0f, 1.0f - cosThetaI * cosThetaI));

    // TIR
    if (sint >= 1.0f) {
        return 1.0f; // 100% reflection
    }

    // Calculate cos of the transmission angle
    float cost = sqrtf(glm::max(0.0f, 1.0f - sint * sint));

    // Schlick approximation
    float Rs = ((etat * cosThetaI) - (etai * cost)) / ((etat * cosThetaI) + (etai * cost));
    float Rp = ((etai * cosThetaI) - (etat * cost)) / ((etai * cosThetaI) + (etat * cost));
    return (Rs * Rs + Rp * Rp) * 0.5f;
}

__device__ void sample_f_glass(
    PathSegment& pathSegment,
    const glm::vec3& woOut,
    float& pdf,
    glm::vec3& f,
    glm::vec3 normal,
    const Material& m,
    const glm::vec3 texCol,
    bool useTexCol,
    thrust::default_random_engine& rng)
{
    thrust::uniform_real_distribution<float> u01(0, 1);
    float r = u01(rng);
    pdf = 1;

    glm::vec3 woWOut = pathSegment.ray.direction;

    float cosi = glm::dot(woWOut, normal);

    float fresnelReflectance = FresnelDielectricEval(cosi);

    if (r < 0.5) {
        sample_f_specular_refl(pathSegment, woOut, pdf, f, normal, m, texCol, useTexCol, rng);
        //f *= 2 * fresnelReflectance; //doubled because we only sample half of the time!
        f *= 2;
    }
    else {
        sample_f_specular_trans(pathSegment, woOut, pdf, f, normal, m, texCol, useTexCol, rng);
        glm::vec3 T = f;
        f *= 2 * (1.f - fresnelReflectance);
        //f *= 2;
    }
}

__device__ void sample_f_specular_refl(
    PathSegment& pathSegment,
    const glm::vec3& woOut,
    float& pdf,
    glm::vec3& f,
    glm::vec3 normal,
    const Material& m,
    const glm::vec3 texCol,
    bool useTexCol,
    thrust::default_random_engine& rng)
{

    glm::vec3 wi = glm::vec3(-woOut.x, -woOut.y, woOut.z);
    if (dot(woOut, normal) > 0) {
        wi = -wi;
    }
    pathSegment.ray.direction = wi;
    pdf = 1;
    glm::vec3 col = m.color;
    if (useTexCol) {
        col = texCol;
    }
    f = col / AbsCosTheta(wi);
}


__device__ void sample_f_specular_trans(
    PathSegment& pathSegment,
    const glm::vec3& woOut,
    float& pdf,
    glm::vec3& f,
    glm::vec3 normal,
    const Material& m,
    const glm::vec3 texCol,
    bool useTexCol,
    thrust::default_random_engine& rng)
{
    pdf = 1;
    // IOR of glass! (refraction based on Snell's law depends on the IOR of mediums. In this case, we have air and glass.)
    float etaA = 1.f;
    float etaB = 1.55f;

    // Potentially swap due to whether we are entering or exiting the glass
    bool entering = CosTheta(woOut) > 0.f;
    float etaI = entering ? etaA : etaB; // incident index
    float etaT = entering ? etaB : etaA; // transmitted index

    // compute ray direction for specular trans
    glm::vec3 wi;
    glm::vec3 wo_local = woOut;

    if (!Refract(wo_local, Faceforward(glm::vec3(0, 0, 1), wo_local), etaI / etaT, wi)) {
        f = glm::vec3(0, 0, 0);
    }

    pathSegment.ray.direction = wi;

    f = glm::vec3(1, 1, 1);
    glm::vec3 col = m.color;
    if (useTexCol) {
        col = texCol;
    }
    f = col / AbsCosTheta(wi);
}

__device__ void f_diffuse(
    glm::vec3& f,
    const Material& m,
    const glm::vec3 texCol,
    bool useTexCol)
{
    glm::vec3 col = m.color;
    if (useTexCol) {
        col = texCol;
    }
    f = INV_PI * col;
}

__device__ void pdf_diffuse(
    float& pdf, const glm::vec3& wi)
{
    pdf = INV_PI * AbsCosTheta(wi);
}

__device__ void sample_f_diffuse(
    PathSegment& pathSegment,
    float& pdf,
    glm::vec3& f,
    glm::vec3 normal,
    const Material& m,
    const glm::vec3 texCol,
    bool useTexCol,
    thrust::default_random_engine& rng)
{
    //0. rng gen
    thrust::uniform_real_distribution<float> u01(0, 1);
    const glm::vec2 xi = glm::vec2(u01(rng), u01(rng));
    //1. Generate wi (local space)
    glm::vec3 wi = glm::vec3(0);
    squareToHemisphereCosine(xi, wi);
    //2. Find f
    f_diffuse(f, m, texCol, useTexCol);

    //3. Find pdf
    pdf_diffuse(pdf, wi);
    //4. update wi
    pathSegment.ray.direction = wi;
}
__host__ __device__ void scatterRay(
    PathSegment& pathSegment,
    glm::vec3 normal,
    thrust::default_random_engine& rng)
{
    //Update ray in pathSegment
    pathSegment.ray.direction = calculateRandomDirectionInHemisphere(normal, rng);
}

__device__ void sample_f(
    PathSegment& pathSegment,
    const glm::vec3& woWOut,
    float& pdf,
    glm::vec3& f,
    glm::vec3 normal,
    const Material& m,
    const glm::vec3 texCol,
    const bool useTexCol,
    thrust::default_random_engine& rng)
{
    glm::vec3 woOut = WorldToLocal(normal) * woWOut;

    switch (m.type) {
        case DIFFUSE_REFL:
            sample_f_diffuse(pathSegment, pdf, f, normal, m, texCol, useTexCol, rng);
            break;
        case SPEC_REFL:
            sample_f_specular_refl(pathSegment, woOut, pdf, f, normal, m, texCol, useTexCol, rng);
            break;
        case SPEC_TRANS:
            sample_f_specular_trans(pathSegment, woOut, pdf, f, normal, m, texCol, useTexCol, rng);
            break;
        case SPEC_GLASS:
            sample_f_glass(pathSegment, woOut, pdf, f, normal, m, texCol, useTexCol, rng);
            break;
        case MICROFACET_REFL:
            sample_f_diffuse(pathSegment, pdf, f, normal, m, texCol, useTexCol, rng);
            break;
        case GLOSSY_REFL:
            sample_f_diffuse(pathSegment, pdf, f, normal, m, texCol, useTexCol, rng);
            break;
        default:
            sample_f_diffuse(pathSegment, pdf, f, normal, m, texCol, useTexCol, rng);
    }

    pathSegment.ray.direction = LocalToWorld(normal) * pathSegment.ray.direction;
}
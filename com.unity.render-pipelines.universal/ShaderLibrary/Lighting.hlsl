#ifndef UNIVERSAL_LIGHTING_INCLUDED
#define UNIVERSAL_LIGHTING_INCLUDED

#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/EntityLighting.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/ImageBasedLighting.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/BSDF.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Deprecated.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SurfaceData.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"

// If lightmap is not defined than we evaluate GI (ambient + probes) from SH
// We might do it fully or partially in vertex to save shader ALU
#if !defined(LIGHTMAP_ON)
// TODO: Controls things like these by exposing SHADER_QUALITY levels (low, medium, high)
    #if defined(SHADER_API_GLES) || !defined(_NORMALMAP)
        // Evaluates SH fully in vertex
        #define EVALUATE_SH_VERTEX
    #elif !SHADER_HINT_NICE_QUALITY
        // Evaluates L2 SH in vertex and L0L1 in pixel
        #define EVALUATE_SH_MIXED
    #endif
        // Otherwise evaluate SH fully per-pixel
#endif

#ifdef LIGHTMAP_ON
    #define DECLARE_LIGHTMAP_OR_SH(lmName, shName, index) float2 lmName : TEXCOORD##index
    #define OUTPUT_LIGHTMAP_UV(lightmapUV, lightmapScaleOffset, OUT) OUT.xy = lightmapUV.xy * lightmapScaleOffset.xy + lightmapScaleOffset.zw;
    #define OUTPUT_SH(normalWS, OUT)
#else
    #define DECLARE_LIGHTMAP_OR_SH(lmName, shName, index) half3 shName : TEXCOORD##index
    #define OUTPUT_LIGHTMAP_UV(lightmapUV, lightmapScaleOffset, OUT)
    #define OUTPUT_SH(normalWS, OUT) OUT.xyz = SampleSHVertex(normalWS)
#endif

// Renamed -> LIGHTMAP_SHADOW_MIXING
#if !defined(_MIXED_LIGHTING_SUBTRACTIVE) && defined(LIGHTMAP_SHADOW_MIXING) && !defined(SHADOWS_SHADOWMASK)
    #define _MIXED_LIGHTING_SUBTRACTIVE
#endif


///////////////////////////////////////////////////////////////////////////////
//                          Light Helpers                                    //
///////////////////////////////////////////////////////////////////////////////

// Abstraction over Light shading data.
struct Light
{
    half3   direction;
    half3   color;
    half    distanceAttenuation;
    half    shadowAttenuation;
};

// WebGL1 does not support the variable conditioned for loops used for additional lights
#if !defined(_USE_WEBGL1_LIGHTS) && defined(UNITY_PLATFORM_WEBGL) && !defined(SHADER_API_GLES3)
    #define _USE_WEBGL1_LIGHTS 1
    #define _WEBGL1_MAX_LIGHTS 8
#else
    #define _USE_WEBGL1_LIGHTS 0
#endif

#if !_USE_WEBGL1_LIGHTS
    #define LIGHT_LOOP_BEGIN(lightCount) \
    for (uint lightIndex = 0u; lightIndex < lightCount; ++lightIndex) {

    #define LIGHT_LOOP_END }
#else
    // WebGL 1 doesn't support variable for loop conditions
    #define LIGHT_LOOP_BEGIN(lightCount) \
    for (int lightIndex = 0; lightIndex < _WEBGL1_MAX_LIGHTS; ++lightIndex) { \
        if (lightIndex >= (int)lightCount) break;

    #define LIGHT_LOOP_END }
#endif

///////////////////////////////////////////////////////////////////////////////
//                        Attenuation Functions                               /
///////////////////////////////////////////////////////////////////////////////

// Matches Unity Vanila attenuation
// Attenuation smoothly decreases to light range.
float DistanceAttenuation(float distanceSqr, half2 distanceAttenuation)
{
    // We use a shared distance attenuation for additional directional and puctual lights
    // for directional lights attenuation will be 1
    float lightAtten = rcp(distanceSqr);
    float2 distanceAttenuationFloat = float2(distanceAttenuation);

#if SHADER_HINT_NICE_QUALITY
    // Use the smoothing factor also used in the Unity lightmapper.
    half factor = half(distanceSqr * distanceAttenuationFloat.x);
    half smoothFactor = saturate(half(1.0) - factor * factor);
    smoothFactor = smoothFactor * smoothFactor;
#else
    // We need to smoothly fade attenuation to light range. We start fading linearly at 80% of light range
    // Therefore:
    // fadeDistance = (0.8 * 0.8 * lightRangeSq)
    // smoothFactor = (lightRangeSqr - distanceSqr) / (lightRangeSqr - fadeDistance)
    // We can rewrite that to fit a MAD by doing
    // distanceSqr * (1.0 / (fadeDistanceSqr - lightRangeSqr)) + (-lightRangeSqr / (fadeDistanceSqr - lightRangeSqr)
    // distanceSqr *        distanceAttenuation.y            +             distanceAttenuation.z
    half smoothFactor = half(saturate(distanceSqr * distanceAttenuationFloat.x + distanceAttenuationFloat.y));
#endif

    return lightAtten * smoothFactor;
}

half AngleAttenuation(half3 spotDirection, half3 lightDirection, half2 spotAttenuation)
{
    // Spot Attenuation with a linear falloff can be defined as
    // (SdotL - cosOuterAngle) / (cosInnerAngle - cosOuterAngle)
    // This can be rewritten as
    // invAngleRange = 1.0 / (cosInnerAngle - cosOuterAngle)
    // SdotL * invAngleRange + (-cosOuterAngle * invAngleRange)
    // SdotL * spotAttenuation.x + spotAttenuation.y

    // If we precompute the terms in a MAD instruction
    half SdotL = dot(spotDirection, lightDirection);
    half atten = saturate(SdotL * spotAttenuation.x + spotAttenuation.y);
    return atten * atten;
}

///////////////////////////////////////////////////////////////////////////////
//                      Light Abstraction                                    //
///////////////////////////////////////////////////////////////////////////////

Light GetMainLight()
{
    Light light;
    light.direction = half3(_MainLightPosition.xyz);
    light.distanceAttenuation = unity_LightData.z; // unity_LightData.z is 1 when not culled by the culling mask, otherwise 0.
    light.shadowAttenuation = 1.0;
    light.color = _MainLightColor.rgb;

    return light;
}

Light GetMainLight(float4 shadowCoord)
{
    Light light = GetMainLight();
    light.shadowAttenuation = MainLightRealtimeShadow(shadowCoord);
    return light;
}

Light GetMainLight(float4 shadowCoord, float3 positionWS, half4 shadowMask)
{
    Light light = GetMainLight();
    light.shadowAttenuation = MainLightShadow(shadowCoord, positionWS, shadowMask, _MainLightOcclusionProbes);
    return light;
}

// Fills a light struct given a perObjectLightIndex
Light GetAdditionalPerObjectLight(int perObjectLightIndex, float3 positionWS)
{
    // Abstraction over Light input constants
#if USE_STRUCTURED_BUFFER_FOR_LIGHT_DATA
    float4 lightPositionWS = _AdditionalLightsBuffer[perObjectLightIndex].position;
    half3 color = _AdditionalLightsBuffer[perObjectLightIndex].color.rgb;
    half4 distanceAndSpotAttenuation = _AdditionalLightsBuffer[perObjectLightIndex].attenuation;
    half4 spotDirection = _AdditionalLightsBuffer[perObjectLightIndex].spotDirection;
#else
    float4 lightPositionWS = _AdditionalLightsPosition[perObjectLightIndex];
    half3 color = _AdditionalLightsColor[perObjectLightIndex].rgb;
    half4 distanceAndSpotAttenuation = _AdditionalLightsAttenuation[perObjectLightIndex];
    half4 spotDirection = _AdditionalLightsSpotDir[perObjectLightIndex];
#endif

    // Directional lights store direction in lightPosition.xyz and have .w set to 0.0.
    // This way the following code will work for both directional and punctual lights.
    float3 lightVector = lightPositionWS.xyz - positionWS * lightPositionWS.w;
    float distanceSqr = max(dot(lightVector, lightVector), HALF_MIN);

    half3 lightDirection = half3(lightVector * rsqrt(distanceSqr));
    half attenuation = half(DistanceAttenuation(distanceSqr, distanceAndSpotAttenuation.xy) * AngleAttenuation(spotDirection.xyz, lightDirection, distanceAndSpotAttenuation.zw));

    Light light;
    light.direction = lightDirection;
    light.distanceAttenuation = attenuation;
    light.shadowAttenuation = 1.0; // This value can later be overridden in GetAdditionalLight(uint i, float3 positionWS, half4 shadowMask)
    light.color = color;

    return light;
}

uint GetPerObjectLightIndexOffset()
{
#if USE_STRUCTURED_BUFFER_FOR_LIGHT_DATA
    return uint(unity_LightData.x);
#else
    return 0;
#endif
}

// Returns a per-object index given a loop index.
// This abstract the underlying data implementation for storing lights/light indices
int GetPerObjectLightIndex(uint index)
{
/////////////////////////////////////////////////////////////////////////////////////////////
// Structured Buffer Path                                                                   /
//                                                                                          /
// Lights and light indices are stored in StructuredBuffer. We can just index them.         /
// Currently all non-mobile platforms take this path :(                                     /
// There are limitation in mobile GPUs to use SSBO (performance / no vertex shader support) /
/////////////////////////////////////////////////////////////////////////////////////////////
#if USE_STRUCTURED_BUFFER_FOR_LIGHT_DATA
    uint offset = uint(unity_LightData.x);
    return _AdditionalLightsIndices[offset + index];

/////////////////////////////////////////////////////////////////////////////////////////////
// UBO path                                                                                 /
//                                                                                          /
// We store 8 light indices in half4 unity_LightIndices[2];                                 /
// Due to memory alignment unity doesn't support int[] or float[]                           /
// Even trying to reinterpret cast the unity_LightIndices to float[] won't work             /
// it will cast to float4[] and create extra register pressure. :(                          /
/////////////////////////////////////////////////////////////////////////////////////////////
#elif !defined(SHADER_API_GLES)
    // since index is uint shader compiler will implement
    // div & mod as bitfield ops (shift and mask).

    // TODO: Can we index a float4? Currently compiler is
    // replacing unity_LightIndicesX[i] with a dp4 with identity matrix.
    // u_xlat16_40 = dot(unity_LightIndices[int(u_xlatu13)], ImmCB_0_0_0[u_xlati1]);
    // This increases both arithmetic and register pressure.
    return int(unity_LightIndices[index / 4][index % 4]);
#else
    // Fallback to GLES2. No bitfield magic here :(.
    // We limit to 4 indices per object and only sample unity_4LightIndices0.
    // Conditional moves are branch free even on mali-400
    // small arithmetic cost but no extra register pressure from ImmCB_0_0_0 matrix.
    half indexHalf = half(index);
    half2 lightIndex2 = (indexHalf < half(2.0)) ? unity_LightIndices[0].xy : unity_LightIndices[0].zw;
    half i_rem = (indexHalf < half(2.0)) ? indexHalf : indexHalf - half(2.0);
    return int((i_rem < half(1.0)) ? lightIndex2.x : lightIndex2.y);
#endif
}

// Fills a light struct given a loop i index. This will convert the i
// index to a perObjectLightIndex
Light GetAdditionalLight(uint i, float3 positionWS)
{
    int perObjectLightIndex = GetPerObjectLightIndex(i);
    return GetAdditionalPerObjectLight(perObjectLightIndex, positionWS);
}

Light GetAdditionalLight(uint i, float3 positionWS, half4 shadowMask)
{
    int perObjectLightIndex = GetPerObjectLightIndex(i);
    Light light = GetAdditionalPerObjectLight(perObjectLightIndex, positionWS);

#if USE_STRUCTURED_BUFFER_FOR_LIGHT_DATA
    half4 occlusionProbeChannels = _AdditionalLightsBuffer[perObjectLightIndex].occlusionProbeChannels;
#else
    half4 occlusionProbeChannels = _AdditionalLightsOcclusionProbes[perObjectLightIndex];
#endif
    light.shadowAttenuation = AdditionalLightShadow(perObjectLightIndex, positionWS, light.direction, shadowMask, occlusionProbeChannels);

    return light;
}

int GetAdditionalLightsCount()
{
    // TODO: we need to expose in SRP api an ability for the pipeline cap the amount of lights
    // in the culling. This way we could do the loop branch with an uniform
    // This would be helpful to support baking exceeding lights in SH as well
    return int(min(_AdditionalLightsCount.x, unity_LightData.y));
}

///////////////////////////////////////////////////////////////////////////////
//                         BRDF Functions                                    //
///////////////////////////////////////////////////////////////////////////////

#define kDielectricSpec half4(0.04, 0.04, 0.04, 1.0 - 0.04) // standard dielectric reflectivity coef at incident angle (= 4%)

struct BRDFData
{
    half3 albedo;
    half3 diffuse;
    half3 specular;
    half reflectivity;
    half perceptualRoughness;
    half roughness;
    half roughness2;
    half grazingTerm;

    // We save some light invariant BRDF terms so we don't have to recompute
    // them in the light loop. Take a look at DirectBRDF function for detailed explaination.
    half normalizationTerm;     // roughness * 4.0 + 2.0
    half roughness2MinusOne;    // roughness^2 - 1.0
};

half ReflectivitySpecular(half3 specular)
{
#if defined(SHADER_API_GLES)
    return specular.r; // Red channel - because most metals are either monocrhome or with redish/yellowish tint
#else
    return Max3(specular.r, specular.g, specular.b);
#endif
}

half OneMinusReflectivityMetallic(half metallic)
{
    // We'll need oneMinusReflectivity, so
    //   1-reflectivity = 1-lerp(dielectricSpec, 1, metallic) = lerp(1-dielectricSpec, 0, metallic)
    // store (1-dielectricSpec) in kDielectricSpec.a, then
    //   1-reflectivity = lerp(alpha, 0, metallic) = alpha + metallic*(0 - alpha) =
    //                  = alpha - metallic * alpha
    half oneMinusDielectricSpec = kDielectricSpec.a;
    return oneMinusDielectricSpec - metallic * oneMinusDielectricSpec;
}

half MetallicFromReflectivity(half reflectivity)
{
    half oneMinusDielectricSpec = kDielectricSpec.a;
    return (reflectivity - kDielectricSpec.r) / oneMinusDielectricSpec;
}

inline void InitializeBRDFDataDirect(half3 albedo, half3 diffuse, half3 specular, half reflectivity, half oneMinusReflectivity, half smoothness, inout half alpha, out BRDFData outBRDFData)
{
    outBRDFData = (BRDFData)0;
    outBRDFData.albedo = albedo;
    outBRDFData.diffuse = diffuse;
    outBRDFData.specular = specular;
    outBRDFData.reflectivity = reflectivity;

    outBRDFData.perceptualRoughness = PerceptualSmoothnessToPerceptualRoughness(smoothness);
    outBRDFData.roughness           = max(PerceptualRoughnessToRoughness(outBRDFData.perceptualRoughness), HALF_MIN_SQRT);
    outBRDFData.roughness2          = max(outBRDFData.roughness * outBRDFData.roughness, HALF_MIN);
    outBRDFData.grazingTerm         = saturate(smoothness + reflectivity);
    outBRDFData.normalizationTerm   = outBRDFData.roughness * half(4.0) + half(2.0);
    outBRDFData.roughness2MinusOne  = outBRDFData.roughness2 - half(1.0);

#ifdef _ALPHAPREMULTIPLY_ON
    outBRDFData.diffuse *= alpha;
    alpha = alpha * oneMinusReflectivity + reflectivity; // NOTE: alpha modified and propagated up.
#endif
}

// Legacy: do not call, will not correctly initialize albedo property.
inline void InitializeBRDFDataDirect(half3 diffuse, half3 specular, half reflectivity, half oneMinusReflectivity, half smoothness, inout half alpha, out BRDFData outBRDFData)
{
    InitializeBRDFDataDirect(half3(0.0, 0.0, 0.0), diffuse, specular, reflectivity, oneMinusReflectivity, smoothness, alpha, outBRDFData);
}

// Initialize BRDFData for material, managing both specular and metallic setup using shader keyword _SPECULAR_SETUP.
inline void InitializeBRDFData(half3 albedo, half metallic, half3 specular, half smoothness, inout half alpha, out BRDFData outBRDFData)
{
#ifdef _SPECULAR_SETUP
    half reflectivity = ReflectivitySpecular(specular);
    half oneMinusReflectivity = half(1.0) - reflectivity;
    half3 brdfDiffuse = albedo * (half3(1.0, 1.0, 1.0) - specular);
    half3 brdfSpecular = specular;
#else
    half oneMinusReflectivity = OneMinusReflectivityMetallic(metallic);
    half reflectivity = half(1.0) - oneMinusReflectivity;
    half3 brdfDiffuse = albedo * oneMinusReflectivity;
    half3 brdfSpecular = lerp(kDieletricSpec.rgb, albedo, metallic);
#endif

    InitializeBRDFDataDirect(albedo, brdfDiffuse, brdfSpecular, reflectivity, oneMinusReflectivity, smoothness, alpha, outBRDFData);
}

half3 ConvertF0ForClearCoat15(half3 f0)
{
#if defined(SHADER_API_MOBILE)
    return ConvertF0ForAirInterfaceToF0ForClearCoat15Fast(f0);
#else
    return ConvertF0ForAirInterfaceToF0ForClearCoat15(f0);
#endif
}

inline void InitializeBRDFDataClearCoat(half clearCoatMask, half clearCoatSmoothness, inout BRDFData baseBRDFData, out BRDFData outBRDFData)
{
    outBRDFData = (BRDFData)0;
    outBRDFData.albedo = half(1.0);

    // Calculate Roughness of Clear Coat layer
    outBRDFData.diffuse             = kDielectricSpec.aaa; // 1 - kDielectricSpec
    outBRDFData.specular            = kDielectricSpec.rgb;
    outBRDFData.reflectivity        = kDielectricSpec.r;

    outBRDFData.perceptualRoughness = PerceptualSmoothnessToPerceptualRoughness(clearCoatSmoothness);
    outBRDFData.roughness           = max(PerceptualRoughnessToRoughness(outBRDFData.perceptualRoughness), HALF_MIN_SQRT);
    outBRDFData.roughness2          = max(outBRDFData.roughness * outBRDFData.roughness, HALF_MIN);
    outBRDFData.normalizationTerm   = outBRDFData.roughness * half(4.0) + half(2.0);
    outBRDFData.roughness2MinusOne  = outBRDFData.roughness2 - half(1.0);
    outBRDFData.grazingTerm         = saturate(clearCoatSmoothness + kDielectricSpec.x);

// Relatively small effect, cut it for lower quality
#if !defined(SHADER_API_MOBILE)
    // Modify Roughness of base layer using coat IOR
    half ieta                        = lerp(1.0h, CLEAR_COAT_IETA, clearCoatMask);
    half coatRoughnessScale          = Sq(ieta);
    half sigma                       = RoughnessToVariance(PerceptualRoughnessToRoughness(baseBRDFData.perceptualRoughness));

    baseBRDFData.perceptualRoughness = RoughnessToPerceptualRoughness(VarianceToRoughness(sigma * coatRoughnessScale));

    // Recompute base material for new roughness, previous computation should be eliminated by the compiler (as it's unused)
    baseBRDFData.roughness          = max(PerceptualRoughnessToRoughness(baseBRDFData.perceptualRoughness), HALF_MIN_SQRT);
    baseBRDFData.roughness2         = max(baseBRDFData.roughness * baseBRDFData.roughness, HALF_MIN);
    baseBRDFData.normalizationTerm  = baseBRDFData.roughness * 4.0h + 2.0h;
    baseBRDFData.roughness2MinusOne = baseBRDFData.roughness2 - 1.0h;
#endif

    // Darken/saturate base layer using coat to surface reflectance (vs. air to surface)
    baseBRDFData.specular = lerp(baseBRDFData.specular, ConvertF0ForClearCoat15(baseBRDFData.specular), clearCoatMask);
    // TODO: what about diffuse? at least in specular workflow diffuse should be recalculated as it directly depends on it.
}

// Computes the specular term for EnvironmentBRDF
half3 EnvironmentBRDFSpecular(BRDFData brdfData, half fresnelTerm)
{
    float surfaceReduction = 1.0 / (brdfData.roughness2 + 1.0);
    return half3(surfaceReduction * lerp(brdfData.specular, brdfData.grazingTerm, fresnelTerm));
}

half3 EnvironmentBRDF(BRDFData brdfData, half3 indirectDiffuse, half3 indirectSpecular, half fresnelTerm)
{
    half3 c = indirectDiffuse * brdfData.diffuse;
    c += indirectSpecular * EnvironmentBRDFSpecular(brdfData, fresnelTerm);
    return c;
}

// Environment BRDF without diffuse for clear coat
half3 EnvironmentBRDFClearCoat(BRDFData brdfData, half clearCoatMask, half3 indirectSpecular, half fresnelTerm)
{
    float surfaceReduction = 1.0 / (brdfData.roughness2 + 1.0);
    return indirectSpecular * EnvironmentBRDFSpecular(brdfData, fresnelTerm) * clearCoatMask;
}

// Computes the scalar specular term for Minimalist CookTorrance BRDF
// NOTE: needs to be multiplied with reflectance f0, i.e. specular color to complete
half DirectBRDFSpecular(BRDFData brdfData, half3 normalWS, half3 lightDirectionWS, half3 viewDirectionWS)
{
    float3 lightDirectionWSFloat3 = float3(lightDirectionWS);
    float3 halfDir = SafeNormalize(lightDirectionWSFloat3 + float3(viewDirectionWS));

    float NoH = saturate(dot(float3(normalWS), halfDir));
    half LoH = half(saturate(dot(lightDirectionWSFloat3, halfDir)));

    // GGX Distribution multiplied by combined approximation of Visibility and Fresnel
    // BRDFspec = (D * V * F) / 4.0
    // D = roughness^2 / ( NoH^2 * (roughness^2 - 1) + 1 )^2
    // V * F = 1.0 / ( LoH^2 * (roughness + 0.5) )
    // See "Optimizing PBR for Mobile" from Siggraph 2015 moving mobile graphics course
    // https://community.arm.com/events/1155

    // Final BRDFspec = roughness^2 / ( NoH^2 * (roughness^2 - 1) + 1 )^2 * (LoH^2 * (roughness + 0.5) * 4.0)
    // We further optimize a few light invariant terms
    // brdfData.normalizationTerm = (roughness + 0.5) * 4.0 rewritten as roughness * 4.0 + 2.0 to a fit a MAD.
    float d = NoH * NoH * brdfData.roughness2MinusOne + 1.00001f;
    half d2 = half(d * d);

    half LoH2 = LoH * LoH;
    half specularTerm = brdfData.roughness2 / (d2 * max(half(0.1), LoH2) * brdfData.normalizationTerm);

    // On platforms where half actually means something, the denominator has a risk of overflow
    // clamp below was added specifically to "fix" that, but dx compiler (we convert bytecode to metal/gles)
    // sees that specularTerm have only non-negative terms, so it skips max(0,..) in clamp (leaving only min(100,...))
#if defined (SHADER_API_MOBILE) || defined (SHADER_API_SWITCH)
    specularTerm = specularTerm - HALF_MIN;
    specularTerm = clamp(specularTerm, 0.0, 100.0); // Prevent FP16 overflow on mobiles
#endif

return specularTerm;
}

// Based on Minimalist CookTorrance BRDF
// Implementation is slightly different from original derivation: http://www.thetenthplanet.de/archives/255
//
// * NDF [Modified] GGX
// * Modified Kelemen and Szirmay-Kalos for Visibility term
// * Fresnel approximated with 1/LdotH
half3 DirectBDRF(BRDFData brdfData, half3 normalWS, half3 lightDirectionWS, half3 viewDirectionWS, bool specularHighlightsOff)
{
    // Can still do compile-time optimisation.
    // If no compile-time optimized, extra overhead if branch taken is around +2.5% on some untethered platforms, -10% if not taken.
    [branch] if (!specularHighlightsOff)
    {
        half specularTerm = DirectBRDFSpecular(brdfData, normalWS, lightDirectionWS, viewDirectionWS);
        half3 color = brdfData.diffuse + specularTerm * brdfData.specular;
        return color;
    }
    else
        return brdfData.diffuse;
}

// Based on Minimalist CookTorrance BRDF
// Implementation is slightly different from original derivation: http://www.thetenthplanet.de/archives/255
//
// * NDF [Modified] GGX
// * Modified Kelemen and Szirmay-Kalos for Visibility term
// * Fresnel approximated with 1/LdotH
half3 DirectBRDF(BRDFData brdfData, half3 normalWS, half3 lightDirectionWS, half3 viewDirectionWS)
{
#ifndef _SPECULARHIGHLIGHTS_OFF
    return brdfData.diffuse + DirectBRDFSpecular(brdfData, normalWS, lightDirectionWS, viewDirectionWS) * brdfData.specular;
#else
    return brdfData.diffuse;
#endif
}

///////////////////////////////////////////////////////////////////////////////
//                      Global Illumination                                  //
///////////////////////////////////////////////////////////////////////////////

// Ambient occlusion
TEXTURE2D_X(_ScreenSpaceOcclusionTexture);
SAMPLER(sampler_ScreenSpaceOcclusionTexture);

struct AmbientOcclusionFactor
{
    half indirectAmbientOcclusion;
    half directAmbientOcclusion;
};

half SampleAmbientOcclusion(float2 normalizedScreenSpaceUV)
{
    float2 uv = UnityStereoTransformScreenSpaceTex(normalizedScreenSpaceUV);
    return half(SAMPLE_TEXTURE2D_X(_ScreenSpaceOcclusionTexture, sampler_ScreenSpaceOcclusionTexture, uv).x);
}

AmbientOcclusionFactor GetScreenSpaceAmbientOcclusion(float2 normalizedScreenSpaceUV)
{
    AmbientOcclusionFactor aoFactor;
    aoFactor.indirectAmbientOcclusion = SampleAmbientOcclusion(normalizedScreenSpaceUV);
    aoFactor.directAmbientOcclusion = lerp(half(1.0), aoFactor.indirectAmbientOcclusion, _AmbientOcclusionParam.w);

    return aoFactor;
}

// Samples SH L0, L1 and L2 terms
half3 SampleSH(half3 normalWS)
{
    // LPPV is not supported in Ligthweight Pipeline
    real4 SHCoefficients[7];
    SHCoefficients[0] = unity_SHAr;
    SHCoefficients[1] = unity_SHAg;
    SHCoefficients[2] = unity_SHAb;
    SHCoefficients[3] = unity_SHBr;
    SHCoefficients[4] = unity_SHBg;
    SHCoefficients[5] = unity_SHBb;
    SHCoefficients[6] = unity_SHC;

    return max(half3(0, 0, 0), SampleSH9(SHCoefficients, normalWS));
}

// SH Vertex Evaluation. Depending on target SH sampling might be
// done completely per vertex or mixed with L2 term per vertex and L0, L1
// per pixel. See SampleSHPixel
half3 SampleSHVertex(half3 normalWS)
{
#if defined(EVALUATE_SH_VERTEX)
    return SampleSH(normalWS);
#elif defined(EVALUATE_SH_MIXED)
    // no max since this is only L2 contribution
    return SHEvalLinearL2(normalWS, unity_SHBr, unity_SHBg, unity_SHBb, unity_SHC);
#endif

    // Fully per-pixel. Nothing to compute.
    return half3(0.0, 0.0, 0.0);
}

// SH Pixel Evaluation. Depending on target SH sampling might be done
// mixed or fully in pixel. See SampleSHVertex
half3 SampleSHPixel(half3 L2Term, half3 normalWS)
{
#if defined(EVALUATE_SH_VERTEX)
    return L2Term;
#elif defined(EVALUATE_SH_MIXED)
    half3 L0L1Term = SHEvalLinearL0L1(normalWS, unity_SHAr, unity_SHAg, unity_SHAb);
    half3 res = L2Term + L0L1Term;
#ifdef UNITY_COLORSPACE_GAMMA
    res = LinearToSRGB(res);
#endif
    return max(half3(0, 0, 0), res);
#endif

    // Default: Evaluate SH fully per-pixel
    return SampleSH(normalWS);
}

#if defined(UNITY_DOTS_INSTANCING_ENABLED)
#define LIGHTMAP_NAME unity_Lightmaps
#define LIGHTMAP_INDIRECTION_NAME unity_LightmapsInd
#define LIGHTMAP_SAMPLER_NAME samplerunity_Lightmaps
#define LIGHTMAP_SAMPLE_EXTRA_ARGS lightmapUV, unity_LightmapIndex.x
#else
#define LIGHTMAP_NAME unity_Lightmap
#define LIGHTMAP_INDIRECTION_NAME unity_LightmapInd
#define LIGHTMAP_SAMPLER_NAME samplerunity_Lightmap
#define LIGHTMAP_SAMPLE_EXTRA_ARGS lightmapUV
#endif

// Sample baked lightmap. Non-Direction and Directional if available.
// Realtime GI is not supported.
half3 SampleLightmap(float2 lightmapUV, half3 normalWS)
{
#ifdef UNITY_LIGHTMAP_FULL_HDR
    bool encodedLightmap = false;
#else
    bool encodedLightmap = true;
#endif

    half4 decodeInstructions = half4(LIGHTMAP_HDR_MULTIPLIER, LIGHTMAP_HDR_EXPONENT, 0.0h, 0.0h);

    // The shader library sample lightmap functions transform the lightmap uv coords to apply bias and scale.
    // However, universal pipeline already transformed those coords in vertex. We pass half4(1, 1, 0, 0) and
    // the compiler will optimize the transform away.
    half4 transformCoords = half4(1, 1, 0, 0);

#if defined(LIGHTMAP_ON) && defined(DIRLIGHTMAP_COMBINED)
    return SampleDirectionalLightmap(TEXTURE2D_LIGHTMAP_ARGS(LIGHTMAP_NAME, LIGHTMAP_SAMPLER_NAME),
        TEXTURE2D_LIGHTMAP_ARGS(LIGHTMAP_INDIRECTION_NAME, LIGHTMAP_SAMPLER_NAME),
        LIGHTMAP_SAMPLE_EXTRA_ARGS, transformCoords, normalWS, encodedLightmap, decodeInstructions);
#elif defined(LIGHTMAP_ON)
    return SampleSingleLightmap(TEXTURE2D_LIGHTMAP_ARGS(LIGHTMAP_NAME, LIGHTMAP_SAMPLER_NAME), LIGHTMAP_SAMPLE_EXTRA_ARGS, transformCoords, encodedLightmap, decodeInstructions);
#else
    return half3(0.0, 0.0, 0.0);
#endif
}

// We either sample GI from baked lightmap or from probes.
// If lightmap: sampleData.xy = lightmapUV
// If probe: sampleData.xyz = L2 SH terms
#if defined(LIGHTMAP_ON)
#define SAMPLE_GI(lmName, shName, normalWSName) SampleLightmap(lmName, normalWSName)
#else
#define SAMPLE_GI(lmName, shName, normalWSName) SampleSHPixel(shName, normalWSName)
#endif

half3 BoxProjectedCubemapDirection(half3 reflectionWS, float3 positionWS, float4 cubemapPositionWS, float4 boxMin, float4 boxMax)
{
    // Is this probe using box projection?
    if (cubemapPositionWS.w > 0.0f)
    {
        float3 boxMinMax = (reflectionWS > 0.0f) ? boxMax.xyz : boxMin.xyz;
        half3 rbMinMax = half3(boxMinMax - positionWS) / reflectionWS;

        half fa = half(min(min(rbMinMax.x, rbMinMax.y), rbMinMax.z));

        half3 worldPos = half3(positionWS - cubemapPositionWS.xyz);

        half3 result = worldPos + reflectionWS * fa;
        return result;
    }
    else
    {
        return reflectionWS;
    }
}

float CalculateProbeWeight(float3 positionWS, float4 probeBoxMin, float4 probeBoxMax)
{
    float blendDistance = probeBoxMax.w;
    float3 weightDir = min(positionWS - probeBoxMin.xyz, probeBoxMax.xyz - positionWS) / blendDistance;
    return saturate(min(weightDir.x, min(weightDir.y, weightDir.z)));
}

half CalculateProbeVolumeSqrMagnitude(float4 probeBoxMin, float4 probeBoxMax)
{
    half3 maxToMin = half3(probeBoxMax.xyz - probeBoxMin.xyz);
    return dot(maxToMin, maxToMin);
}

half3 CalculateIrradianceFromReflectionProbes(half3 reflectVector, float3 positionWS, half perceptualRoughness)
{
    half probe0Volume = CalculateProbeVolumeSqrMagnitude(unity_SpecCube0_BoxMin, unity_SpecCube0_BoxMax);
    half probe1Volume = CalculateProbeVolumeSqrMagnitude(unity_SpecCube1_BoxMin, unity_SpecCube1_BoxMax);

    half volumeDiff = probe0Volume - probe1Volume;
    float importanceSign = unity_SpecCube1_BoxMin.w;

    // A probe is dominant if its importance is higher
    // Or have equal importance but smaller volume
    bool probe0Dominant = importanceSign > 0.0f || (importanceSign == 0.0f && volumeDiff < -0.0001h);
    bool probe1Dominant = importanceSign < 0.0f || (importanceSign == 0.0f && volumeDiff > 0.0001h);

    float desiredWeightProbe0 = CalculateProbeWeight(positionWS, unity_SpecCube0_BoxMin, unity_SpecCube0_BoxMax);
    float desiredWeightProbe1 = CalculateProbeWeight(positionWS, unity_SpecCube1_BoxMin, unity_SpecCube1_BoxMax);

    // Subject the probes weight if the other probe is dominant
    float weightProbe0 = probe1Dominant ? min(desiredWeightProbe0, 1.0f - desiredWeightProbe1) : desiredWeightProbe0;
    float weightProbe1 = probe0Dominant ? min(desiredWeightProbe1, 1.0f - desiredWeightProbe0) : desiredWeightProbe1;

    float totalWeight = weightProbe0 + weightProbe1;

    // If either probe 0 or probe 1 is dominant the sum of weights is guaranteed to be 1.
    // If neither is dominant this is not guaranteed - only normalize weights if totalweight exceeds 1.
    weightProbe0 /= max(totalWeight, 1.0f);
    weightProbe1 /= max(totalWeight, 1.0f);

    half3 irradiance = half3(0.0h, 0.0h, 0.0h);
    half3 originalReflectVector = reflectVector;
    half mip = PerceptualRoughnessToMipmapLevel(perceptualRoughness);

    // Sample the first reflection probe
    if (weightProbe0 > 0.01f)
    {
#ifdef _REFLECTION_PROBE_BOX_PROJECTION
        reflectVector = BoxProjectedCubemapDirection(originalReflectVector, positionWS, unity_SpecCube0_ProbePosition, unity_SpecCube0_BoxMin, unity_SpecCube0_BoxMax);
#endif // _REFLECTION_PROBE_BOX_PROJECTION

        half4 encodedIrradiance = half4(SAMPLE_TEXTURECUBE_LOD(unity_SpecCube0, samplerunity_SpecCube0, reflectVector, mip));

#if defined(UNITY_USE_NATIVE_HDR) || defined(UNITY_DOTS_INSTANCING_ENABLED)
        irradiance += weightProbe0 * encodedIrradiance.rbg;
#else
        irradiance += weightProbe0 * DecodeHDREnvironment(encodedIrradiance, unity_SpecCube0_HDR);
#endif // UNITY_USE_NATIVE_HDR || UNITY_DOTS_INSTANCING_ENABLED
    }

    // Sample the second reflection probe
    if (weightProbe1 > 0.01f)
    {
#ifdef _REFLECTION_PROBE_BOX_PROJECTION
        reflectVector = BoxProjectedCubemapDirection(originalReflectVector, positionWS, unity_SpecCube1_ProbePosition, unity_SpecCube1_BoxMin, unity_SpecCube1_BoxMax);
#endif // _REFLECTION_PROBE_BOX_PROJECTION
        half4 encodedIrradiance = half4(SAMPLE_TEXTURECUBE_LOD(unity_SpecCube1, samplerunity_SpecCube1, reflectVector, mip));

#if defined(UNITY_USE_NATIVE_HDR) || defined(UNITY_DOTS_INSTANCING_ENABLED)
        irradiance += weightProbe1 * encodedIrradiance.rbg;
#else
        irradiance += weightProbe1 * DecodeHDREnvironment(encodedIrradiance, unity_SpecCube1_HDR);
#endif // UNITY_USE_NATIVE_HDR || UNITY_DOTS_INSTANCING_ENABLED
    }

    // Use any remaining weight to blend to environment reflection cube map
    if (totalWeight < 0.99f)
    {
        half4 encodedIrradiance = half4(SAMPLE_TEXTURECUBE_LOD(_GlossyEnvironmentCubeMap, sampler_GlossyEnvironmentCubeMap, originalReflectVector, mip));

#if defined(UNITY_USE_NATIVE_HDR) || defined(UNITY_DOTS_INSTANCING_ENABLED)
        irradiance += (1.0f - totalWeight) * encodedIrradiance.rbg;
#else
        irradiance += (1.0f - totalWeight) * DecodeHDREnvironment(encodedIrradiance, _GlossyEnvironmentCubeMap_HDR);
#endif // UNITY_USE_NATIVE_HDR || UNITY_DOTS_INSTANCING_ENABLED
    }

    return irradiance;
}

half3 GlossyEnvironmentReflection(half3 reflectVector, float3 positionWS, half perceptualRoughness, half occlusion)
{
#if !defined(_ENVIRONMENTREFLECTIONS_OFF)
    half3 irradiance;

#ifdef _REFLECTION_PROBE_BLENDING
    irradiance = CalculateIrradianceFromReflectionProbes(reflectVector, positionWS, perceptualRoughness);
#else
#ifdef _REFLECTION_PROBE_BOX_PROJECTION
    reflectVector = BoxProjectedCubemapDirection(reflectVector, positionWS, unity_SpecCube0_ProbePosition, unity_SpecCube0_BoxMin, unity_SpecCube0_BoxMax);
#endif // _REFLECTION_PROBE_BOX_PROJECTION
    half mip = PerceptualRoughnessToMipmapLevel(perceptualRoughness);
    half4 encodedIrradiance = half4(SAMPLE_TEXTURECUBE_LOD(unity_SpecCube0, samplerunity_SpecCube0, reflectVector, mip));

    //TODO:DOTS - we need to port probes to live in c# so we can manage this manually.
#if defined(UNITY_USE_NATIVE_HDR) || defined(UNITY_DOTS_INSTANCING_ENABLED)
    irradiance = encodedIrradiance.rgb;
#else
    irradiance = DecodeHDREnvironment(encodedIrradiance, unity_SpecCube0_HDR);
#endif // UNITY_USE_NATIVE_HDR || UNITY_DOTS_INSTANCING_ENABLED
#endif // _REFLECTION_PROBE_BLENDING
    return irradiance * occlusion;
#else
    return _GlossyEnvironmentColor.rgb * occlusion;
#endif // _ENVIRONMENTREFLECTIONS_OFF
}

half3 GlossyEnvironmentReflection(half3 reflectVector, half perceptualRoughness, half occlusion)
{
#if !defined(_ENVIRONMENTREFLECTIONS_OFF)
    half3 irradiance;
    half mip = PerceptualRoughnessToMipmapLevel(perceptualRoughness);
    half4 encodedIrradiance = half4(SAMPLE_TEXTURECUBE_LOD(unity_SpecCube0, samplerunity_SpecCube0, reflectVector, mip));

    //TODO:DOTS - we need to port probes to live in c# so we can manage this manually.
#if defined(UNITY_USE_NATIVE_HDR) || defined(UNITY_DOTS_INSTANCING_ENABLED)
    irradiance = encodedIrradiance.rgb;
#else
    irradiance = DecodeHDREnvironment(encodedIrradiance, unity_SpecCube0_HDR);
#endif // UNITY_USE_NATIVE_HDR || UNITY_DOTS_INSTANCING_ENABLED

    return irradiance * occlusion;
#else
    return _GlossyEnvironmentColor.rgb * occlusion;
#endif // _ENVIRONMENTREFLECTIONS_OFF
}

half3 SubtractDirectMainLightFromLightmap(Light mainLight, half3 normalWS, half3 bakedGI)
{
    // Let's try to make realtime shadows work on a surface, which already contains
    // baked lighting and shadowing from the main sun light.
    // Summary:
    // 1) Calculate possible value in the shadow by subtracting estimated light contribution from the places occluded by realtime shadow:
    //      a) preserves other baked lights and light bounces
    //      b) eliminates shadows on the geometry facing away from the light
    // 2) Clamp against user defined ShadowColor.
    // 3) Pick original lightmap value, if it is the darkest one.


    // 1) Gives good estimate of illumination as if light would've been shadowed during the bake.
    // We only subtract the main direction light. This is accounted in the contribution term below.
    half shadowStrength = GetMainLightShadowStrength();
    half contributionTerm = saturate(dot(mainLight.direction, normalWS));
    half3 lambert = mainLight.color * contributionTerm;
    half3 estimatedLightContributionMaskedByInverseOfShadow = lambert * (1.0 - mainLight.shadowAttenuation);
    half3 subtractedLightmap = bakedGI - estimatedLightContributionMaskedByInverseOfShadow;

    // 2) Allows user to define overall ambient of the scene and control situation when realtime shadow becomes too dark.
    half3 realtimeShadow = max(subtractedLightmap, _SubtractiveShadowColor.xyz);
    realtimeShadow = lerp(bakedGI, realtimeShadow, shadowStrength);

    // 3) Pick darkest color
    return min(bakedGI, realtimeShadow);
}

half3 GlobalIllumination(BRDFData brdfData, BRDFData brdfDataClearCoat, float clearCoatMask,
    half3 bakedGI, half occlusion, float3 positionWS,
    half3 normalWS, half3 viewDirectionWS)
{
    half3 reflectVector = reflect(-viewDirectionWS, normalWS);
    half NoV = saturate(dot(normalWS, viewDirectionWS));
    half fresnelTerm = Pow4(1.0 - NoV);

    half3 indirectDiffuse = bakedGI;
    half3 indirectSpecular = GlossyEnvironmentReflection(reflectVector, positionWS, brdfData.perceptualRoughness, 1.0h);

    half3 color = EnvironmentBRDF(brdfData, indirectDiffuse, indirectSpecular, fresnelTerm);

#if defined(_CLEARCOAT) || defined(_CLEARCOATMAP)
    half3 coatIndirectSpecular = GlossyEnvironmentReflection(reflectVector, positionWS, brdfDataClearCoat.perceptualRoughness, 1.0h);
    // TODO: "grazing term" causes problems on full roughness
    half3 coatColor = EnvironmentBRDFClearCoat(brdfDataClearCoat, clearCoatMask, coatIndirectSpecular, fresnelTerm);

    // Blend with base layer using khronos glTF recommended way using NoV
    // Smooth surface & "ambiguous" lighting
    // NOTE: fresnelTerm (above) is pow4 instead of pow5, but should be ok as blend weight.
    half coatFresnel = kDielectricSpec.x + kDielectricSpec.a * fresnelTerm;
    return (color * (1.0 - coatFresnel * clearCoatMask) + coatColor) * occlusion;
#else
    return color * occlusion;
#endif
}

// Backwards compatiblity
half3 GlobalIllumination(BRDFData brdfData, half3 bakedGI, half occlusion, float3 positionWS, half3 normalWS, half3 viewDirectionWS)
{
    const BRDFData noClearCoat = (BRDFData)0;
    return GlobalIllumination(brdfData, noClearCoat, 0.0, bakedGI, occlusion, positionWS, normalWS, viewDirectionWS);
}
half3 GlobalIllumination(BRDFData brdfData, BRDFData brdfDataClearCoat, float clearCoatMask,
    half3 bakedGI, half occlusion,
    half3 normalWS, half3 viewDirectionWS)
{
    half3 reflectVector = reflect(-viewDirectionWS, normalWS);
    half NoV = saturate(dot(normalWS, viewDirectionWS));
    half fresnelTerm = Pow4(1.0 - NoV);

    half3 indirectDiffuse = bakedGI;
    half3 indirectSpecular = GlossyEnvironmentReflection(reflectVector, brdfData.perceptualRoughness, half(1.0));

    half3 color = EnvironmentBRDF(brdfData, indirectDiffuse, indirectSpecular, fresnelTerm);

#if defined(_CLEARCOAT) || defined(_CLEARCOATMAP)
    half3 coatIndirectSpecular = GlossyEnvironmentReflection(reflectVector, brdfDataClearCoat.perceptualRoughness, half(1.0));
    // TODO: "grazing term" causes problems on full roughness
    half3 coatColor = EnvironmentBRDFClearCoat(brdfDataClearCoat, clearCoatMask, coatIndirectSpecular, fresnelTerm);

    // Blend with base layer using khronos glTF recommended way using NoV
    // Smooth surface & "ambiguous" lighting
    // NOTE: fresnelTerm (above) is pow4 instead of pow5, but should be ok as blend weight.
    half coatFresnel = kDielectricSpec.x + kDielectricSpec.a * fresnelTerm;
    return (color * (1.0 - coatFresnel * clearCoatMask) + coatColor) * occlusion;
#else
    return color * occlusion;
#endif
}

half3 GlobalIllumination(BRDFData brdfData, half3 bakedGI, half occlusion, half3 normalWS, half3 viewDirectionWS)
{
    const BRDFData noClearCoat = (BRDFData)0;
    return GlobalIllumination(brdfData, noClearCoat, 0.0, bakedGI, occlusion, normalWS, viewDirectionWS);
}

void MixRealtimeAndBakedGI(inout Light light, half3 normalWS, inout half3 bakedGI)
{
#if defined(LIGHTMAP_ON) && defined(_MIXED_LIGHTING_SUBTRACTIVE)
    bakedGI = SubtractDirectMainLightFromLightmap(light, normalWS, bakedGI);
#endif
}

// Backwards compatiblity
void MixRealtimeAndBakedGI(inout Light light, half3 normalWS, inout half3 bakedGI, half4 shadowMask)
{
    MixRealtimeAndBakedGI(light, normalWS, bakedGI);
}

///////////////////////////////////////////////////////////////////////////////
//                      Lighting Functions                                   //
///////////////////////////////////////////////////////////////////////////////
half3 LightingLambert(half3 lightColor, half3 lightDir, half3 normal)
{
    half NdotL = saturate(dot(normal, lightDir));
    return lightColor * NdotL;
}

half3 LightingSpecular(half3 lightColor, half3 lightDir, half3 normal, half3 viewDir, half4 specular, half smoothness)
{
    float3 halfVec = SafeNormalize(float3(lightDir) + float3(viewDir));
    half NdotH = half(saturate(dot(normal, halfVec)));
    half modifier = pow(NdotH, smoothness);
    half3 specularReflection = specular.rgb * modifier;
    return lightColor * specularReflection;
}

half3 LightingPhysicallyBased(BRDFData brdfData, BRDFData brdfDataClearCoat,
    half3 lightColor, half3 lightDirectionWS, half lightAttenuation,
    half3 normalWS, half3 viewDirectionWS,
    half clearCoatMask, bool specularHighlightsOff)
{
    half NdotL = saturate(dot(normalWS, lightDirectionWS));
    half3 radiance = lightColor * (lightAttenuation * NdotL);

    half3 brdf = brdfData.diffuse;
#ifndef _SPECULARHIGHLIGHTS_OFF
    [branch] if (!specularHighlightsOff)
    {
        brdf += brdfData.specular * DirectBRDFSpecular(brdfData, normalWS, lightDirectionWS, viewDirectionWS);

#if defined(_CLEARCOAT) || defined(_CLEARCOATMAP)
        // Clear coat evaluates the specular a second timw and has some common terms with the base specular.
        // We rely on the compiler to merge these and compute them only once.
        half brdfCoat = kDielectricSpec.r * DirectBRDFSpecular(brdfDataClearCoat, normalWS, lightDirectionWS, viewDirectionWS);

            // Mix clear coat and base layer using khronos glTF recommended formula
            // https://github.com/KhronosGroup/glTF/blob/master/extensions/2.0/Khronos/KHR_materials_clearcoat/README.md
            // Use NoV for direct too instead of LoH as an optimization (NoV is light invariant).
            half NoV = saturate(dot(normalWS, viewDirectionWS));
            // Use slightly simpler fresnelTerm (Pow4 vs Pow5) as a small optimization.
            // It is matching fresnel used in the GI/Env, so should produce a consistent clear coat blend (env vs. direct)
            half coatFresnel = kDielectricSpec.x + kDielectricSpec.a * Pow4(1.0 - NoV);

        brdf = brdf * (1.0 - clearCoatMask * coatFresnel) + brdfCoat * clearCoatMask;
#endif // _CLEARCOAT
    }
#endif // _SPECULARHIGHLIGHTS_OFF

    return brdf * radiance;
}

half3 LightingPhysicallyBased(BRDFData brdfData, BRDFData brdfDataClearCoat, Light light, half3 normalWS, half3 viewDirectionWS, half clearCoatMask, bool specularHighlightsOff)
{
    return LightingPhysicallyBased(brdfData, brdfDataClearCoat, light.color, light.direction, light.distanceAttenuation * light.shadowAttenuation, normalWS, viewDirectionWS, clearCoatMask, specularHighlightsOff);
}

// Backwards compatibility
half3 LightingPhysicallyBased(BRDFData brdfData, Light light, half3 normalWS, half3 viewDirectionWS)
{
    #ifdef _SPECULARHIGHLIGHTS_OFF
    bool specularHighlightsOff = true;
#else
    bool specularHighlightsOff = false;
#endif
    const BRDFData noClearCoat = (BRDFData)0;
    return LightingPhysicallyBased(brdfData, noClearCoat, light, normalWS, viewDirectionWS, 0.0, specularHighlightsOff);
}

half3 LightingPhysicallyBased(BRDFData brdfData, half3 lightColor, half3 lightDirectionWS, half lightAttenuation, half3 normalWS, half3 viewDirectionWS)
{
    Light light;
    light.color = lightColor;
    light.direction = lightDirectionWS;
    light.distanceAttenuation = lightAttenuation;
    light.shadowAttenuation   = 1;
    return LightingPhysicallyBased(brdfData, light, normalWS, viewDirectionWS);
}

half3 LightingPhysicallyBased(BRDFData brdfData, Light light, half3 normalWS, half3 viewDirectionWS, bool specularHighlightsOff)
{
    const BRDFData noClearCoat = (BRDFData)0;
    return LightingPhysicallyBased(brdfData, noClearCoat, light, normalWS, viewDirectionWS, 0.0, specularHighlightsOff);
}

half3 LightingPhysicallyBased(BRDFData brdfData, half3 lightColor, half3 lightDirectionWS, half lightAttenuation, half3 normalWS, half3 viewDirectionWS, bool specularHighlightsOff)
{
    Light light;
    light.color = lightColor;
    light.direction = lightDirectionWS;
    light.distanceAttenuation = lightAttenuation;
    light.shadowAttenuation   = 1;
    return LightingPhysicallyBased(brdfData, light, viewDirectionWS, specularHighlightsOff, specularHighlightsOff);
}

half3 VertexLighting(float3 positionWS, half3 normalWS)
{
    half3 vertexLightColor = half3(0.0, 0.0, 0.0);

#ifdef _ADDITIONAL_LIGHTS_VERTEX
    uint lightsCount = GetAdditionalLightsCount();
    LIGHT_LOOP_BEGIN(lightsCount)
        Light light = GetAdditionalLight(lightIndex, positionWS);
        half3 lightColor = light.color * light.distanceAttenuation;
        vertexLightColor += LightingLambert(lightColor, light.direction, normalWS);
    LIGHT_LOOP_END
#endif

    return vertexLightColor;
}

///////////////////////////////////////////////////////////////////////////////
//                      Fragment Functions                                   //
//       Used by ShaderGraph and others builtin renderers                    //
///////////////////////////////////////////////////////////////////////////////
half4 UniversalFragmentPBR(InputData inputData, SurfaceData surfaceData)
{
#ifdef _SPECULARHIGHLIGHTS_OFF
    bool specularHighlightsOff = true;
#else
    bool specularHighlightsOff = false;
#endif

    BRDFData brdfData;

    // NOTE: can modify alpha
    InitializeBRDFData(surfaceData.albedo, surfaceData.metallic, surfaceData.specular, surfaceData.smoothness, surfaceData.alpha, brdfData);

    BRDFData brdfDataClearCoat = (BRDFData)0;
#if defined(_CLEARCOAT) || defined(_CLEARCOATMAP)
    // base brdfData is modified here, rely on the compiler to eliminate dead computation by InitializeBRDFData()
    InitializeBRDFDataClearCoat(surfaceData.clearCoatMask, surfaceData.clearCoatSmoothness, brdfData, brdfDataClearCoat);
#endif

    // To ensure backward compatibility we have to avoid using shadowMask input, as it is not present in older shaders
#if defined(SHADOWS_SHADOWMASK) && defined(LIGHTMAP_ON)
    half4 shadowMask = inputData.shadowMask;
#elif !defined (LIGHTMAP_ON)
    half4 shadowMask = unity_ProbesOcclusion;
#else
    half4 shadowMask = half4(1, 1, 1, 1);
#endif

    Light mainLight = GetMainLight(inputData.shadowCoord, inputData.positionWS, shadowMask);

    #if defined(_SCREEN_SPACE_OCCLUSION) && !defined(_SURFACE_TYPE_TRANSPARENT)
        AmbientOcclusionFactor aoFactor = GetScreenSpaceAmbientOcclusion(inputData.normalizedScreenSpaceUV);
        mainLight.color *= aoFactor.directAmbientOcclusion;
        surfaceData.occlusion = min(surfaceData.occlusion, aoFactor.indirectAmbientOcclusion);
    #endif

    MixRealtimeAndBakedGI(mainLight, inputData.normalWS, inputData.bakedGI);
    half3 color = GlobalIllumination(brdfData, brdfDataClearCoat, surfaceData.clearCoatMask,
                                     inputData.bakedGI, surfaceData.occlusion, inputData.positionWS,
                                     inputData.normalWS, inputData.viewDirectionWS);
    color += LightingPhysicallyBased(brdfData, brdfDataClearCoat,
                                     mainLight,
                                     inputData.normalWS, inputData.viewDirectionWS,
                                     surfaceData.clearCoatMask, specularHighlightsOff);

#ifdef _ADDITIONAL_LIGHTS
    uint pixelLightCount = GetAdditionalLightsCount();
    LIGHT_LOOP_BEGIN(pixelLightCount)
        Light light = GetAdditionalLight(lightIndex, inputData.positionWS, shadowMask);
        #if defined(_SCREEN_SPACE_OCCLUSION) && !defined(_SURFACE_TYPE_TRANSPARENT)
            light.color *= aoFactor.directAmbientOcclusion;
        #endif
        color += LightingPhysicallyBased(brdfData, brdfDataClearCoat,
                                         light,
                                         inputData.normalWS, inputData.viewDirectionWS,
                                         surfaceData.clearCoatMask, specularHighlightsOff);
    LIGHT_LOOP_END
#endif

#ifdef _ADDITIONAL_LIGHTS_VERTEX
    color += inputData.vertexLighting * brdfData.diffuse;
#endif

    color += surfaceData.emission;

    return half4(color, surfaceData.alpha);
}

half4 UniversalFragmentPBR(InputData inputData, half3 albedo, half metallic, half3 specular,
    half smoothness, half occlusion, half3 emission, half alpha)
{
    SurfaceData s;
    s.albedo              = albedo;
    s.metallic            = metallic;
    s.specular            = specular;
    s.smoothness          = smoothness;
    s.occlusion           = occlusion;
    s.emission            = emission;
    s.alpha               = alpha;
    s.clearCoatMask       = 0.0;
    s.clearCoatSmoothness = 1.0;
    return UniversalFragmentPBR(inputData, s);
}

half4 UniversalFragmentBlinnPhong(InputData inputData, half3 diffuse, half4 specularGloss, half smoothness, half3 emission, half alpha)
{
    // To ensure backward compatibility we have to avoid using shadowMask input, as it is not present in older shaders
#if defined(SHADOWS_SHADOWMASK) && defined(LIGHTMAP_ON)
    half4 shadowMask = inputData.shadowMask;
#elif !defined (LIGHTMAP_ON)
    half4 shadowMask = unity_ProbesOcclusion;
#else
    half4 shadowMask = half4(1, 1, 1, 1);
#endif

    Light mainLight = GetMainLight(inputData.shadowCoord, inputData.positionWS, shadowMask);

    #if defined(_SCREEN_SPACE_OCCLUSION) && !defined(_SURFACE_TYPE_TRANSPARENT)
        AmbientOcclusionFactor aoFactor = GetScreenSpaceAmbientOcclusion(inputData.normalizedScreenSpaceUV);
        mainLight.color *= aoFactor.directAmbientOcclusion;
        inputData.bakedGI *= aoFactor.indirectAmbientOcclusion;
    #endif

    MixRealtimeAndBakedGI(mainLight, inputData.normalWS, inputData.bakedGI);

    half3 attenuatedLightColor = mainLight.color * (mainLight.distanceAttenuation * mainLight.shadowAttenuation);
    half3 diffuseColor = inputData.bakedGI + LightingLambert(attenuatedLightColor, mainLight.direction, inputData.normalWS);
    half3 specularColor = LightingSpecular(attenuatedLightColor, mainLight.direction, inputData.normalWS, inputData.viewDirectionWS, specularGloss, smoothness);

#ifdef _ADDITIONAL_LIGHTS
    uint pixelLightCount = GetAdditionalLightsCount();
    LIGHT_LOOP_BEGIN(pixelLightCount)
        Light light = GetAdditionalLight(lightIndex, inputData.positionWS, shadowMask);
        #if defined(_SCREEN_SPACE_OCCLUSION) && !defined(_SURFACE_TYPE_TRANSPARENT)
            light.color *= aoFactor.directAmbientOcclusion;
        #endif
        half3 attenuatedLightColor = light.color * (light.distanceAttenuation * light.shadowAttenuation);
        diffuseColor += LightingLambert(attenuatedLightColor, light.direction, inputData.normalWS);
        specularColor += LightingSpecular(attenuatedLightColor, light.direction, inputData.normalWS, inputData.viewDirectionWS, specularGloss, smoothness);
    LIGHT_LOOP_END
#endif

#ifdef _ADDITIONAL_LIGHTS_VERTEX
    diffuseColor += inputData.vertexLighting;
#endif

    half3 finalColor = diffuseColor * diffuse + emission;

#if defined(_SPECGLOSSMAP) || defined(_SPECULAR_COLOR)
    finalColor += specularColor;
#endif

    return half4(finalColor, alpha);
}

//LWRP -> Universal Backwards Compatibility
half4 LightweightFragmentPBR(InputData inputData, half3 albedo, half metallic, half3 specular,
    half smoothness, half occlusion, half3 emission, half alpha)
{
    return UniversalFragmentPBR(inputData, albedo, metallic, specular, smoothness, occlusion, emission, alpha);
}

half4 LightweightFragmentBlinnPhong(InputData inputData, half3 diffuse, half4 specularGloss, half smoothness, half3 emission, half alpha)
{
    return UniversalFragmentBlinnPhong(inputData, diffuse, specularGloss, smoothness, emission, alpha);
}
#endif

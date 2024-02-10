using System;
using System.Collections.Generic;
using Unity.Collections;
using Unity.Jobs;
using UnityEngine.Profiling;
using Unity.Mathematics;
using UnityEngine.Assertions;
using UnityEngine.Rendering.RenderGraphModule;

namespace UnityEngine.Rendering
{
    internal partial class GPUResidentBatcher : IDisposable
    {
        private RenderersBatchersContext m_BatchersContext;
        private GPUDrivenProcessor m_GPUDrivenProcessor;
        private GPUDrivenRendererDataCallback m_UpdateRendererDataCallback;

        internal RenderersBatchersContext batchersContext { get => m_BatchersContext; }
        internal OcclusionCullingCommon occlusionCullingCommon { get => m_BatchersContext.occlusionCullingCommon; }
        internal InstanceCullingBatcher instanceCullingBatcher { get => m_InstanceCullingBatcher; }

        private InstanceCullingBatcher m_InstanceCullingBatcher = null;

        private ParallelBitArray m_ProcessedThisFrameTreeBits;
        private NativeParallelHashMap<LightmapManager.RendererSubmeshPair, int> m_RendererToMaterialMapDummy;

        public GPUResidentBatcher(
            RenderersBatchersContext batcherContext,
            InstanceCullingBatcherDesc instanceCullerBatcherDesc,
            GPUDrivenProcessor gpuDrivenProcessor)
        {
            m_BatchersContext = batcherContext;
            m_GPUDrivenProcessor = gpuDrivenProcessor;
            m_UpdateRendererDataCallback = UpdateRendererData;

            m_InstanceCullingBatcher = new InstanceCullingBatcher(batcherContext, instanceCullerBatcherDesc, OnFinishedCulling);
            // We need this in case lightmap texture arrays are disabled and we cannot get it from the lightmap manager,
            // because a map is always expected when creating the draw batches.
            m_RendererToMaterialMapDummy = new NativeParallelHashMap<LightmapManager.RendererSubmeshPair, int>(0,
                Allocator.Persistent);
        }

        public void Dispose()
        {
            m_GPUDrivenProcessor.ClearMaterialFilters();
            m_InstanceCullingBatcher.Dispose();
            m_RendererToMaterialMapDummy.Dispose();

            if (m_ProcessedThisFrameTreeBits.IsCreated)
                m_ProcessedThisFrameTreeBits.Dispose();
        }

        public void OnBeginContextRendering()
        {
            if (m_ProcessedThisFrameTreeBits.IsCreated)
                m_ProcessedThisFrameTreeBits.Dispose();
        }

        public void OnEndContextRendering()
        {
            m_InstanceCullingBatcher?.OnEndContextRendering();
        }

        public void OnBeginCameraRendering(Camera camera)
        {
            m_InstanceCullingBatcher?.OnBeginCameraRendering(camera);
        }

        public void OnEndCameraRendering(Camera camera)
        {
            m_InstanceCullingBatcher?.OnEndCameraRendering(camera);
        }

        public void UpdateFrame()
        {
            m_InstanceCullingBatcher.UpdateFrame();
            m_BatchersContext.UpdateFrame();
        }

        public void DestroyMaterials(NativeArray<int> destroyedMaterials)
        {
            m_InstanceCullingBatcher.DestroyMaterials(destroyedMaterials);
        }

        public void DestroyInstances(NativeArray<InstanceHandle> instances)
        {
            m_InstanceCullingBatcher.DestroyInstances(instances);
        }

        public void DestroyMeshes(NativeArray<int> destroyedMeshes)
        {
            m_InstanceCullingBatcher.DestroyMeshes(destroyedMeshes);
        }

        public void InstanceOcclusionTest(RenderGraph renderGraph, in OcclusionCullingSettings settings)
        {
            if (!m_BatchersContext.hasBoundingSpheres)
                return;

            m_InstanceCullingBatcher.culler.InstanceOcclusionTest(renderGraph, settings, m_BatchersContext);
        }

        public void UpdateInstanceOccluders(RenderGraph renderGraph, in OccluderParameters occluderParams)
        {
            if (!m_BatchersContext.hasBoundingSpheres)
                return;

            m_BatchersContext.occlusionCullingCommon.UpdateInstanceOccluders(renderGraph, occluderParams);
        }

        public void UpdateRenderers(NativeArray<int> renderersID)
        {
            if (renderersID.Length == 0)
                return;

            m_GPUDrivenProcessor.enablePartialRendering = false;
            m_GPUDrivenProcessor.EnableGPUDrivenRenderingAndDispatchRendererData(renderersID, m_UpdateRendererDataCallback);
            m_GPUDrivenProcessor.enablePartialRendering = false;
        }

        public void PostCullBeginCameraRendering(RenderRequestBatcherContext context)
        {
            RenderSettings.ambientProbe = context.ambientProbe;
            m_BatchersContext.UpdateAmbientProbeAndGpuBuffer(context.ambientProbe);
            m_InstanceCullingBatcher.PostCullBeginCameraRendering(context);
        }

        private void UpdateRendererData(in GPUDrivenRendererGroupData rendererData, IList<Mesh> meshes, IList<Material> materials)
        {
            if (rendererData.rendererGroupID.Length == 0)
                return;

            Profiler.BeginSample("GPUResidentInstanceBatcher.UpdateRendererData");
            {
                var usedMaterialIDs = new NativeList<int>(Allocator.TempJob);
                usedMaterialIDs.AddRange(rendererData.materialID);
                NativeParallelHashMap<LightmapManager.RendererSubmeshPair, int> rendererToMaterialMap;
                NativeArray<float4> lightMapTextureIndices;

                // ----------------------------------------------------------------------------------------------------------------------------------
                // Register lightmaps.
                // ----------------------------------------------------------------------------------------------------------------------------------
                Profiler.BeginSample("GenerateLightmappingData");
                {
                    // The lightmap manager may be null here if lightmap texture arrays are disabled
                    rendererToMaterialMap = m_BatchersContext.lightmapManager?.GenerateLightmappingData(rendererData, materials, usedMaterialIDs) ?? m_RendererToMaterialMapDummy;
                    Profiler.BeginSample("GetLightmapTextureIndex");
                    lightMapTextureIndices = new NativeArray<float4>(rendererData.rendererGroupID.Length, Allocator.TempJob, NativeArrayOptions.UninitializedMemory);
                    m_BatchersContext.lightmapManager?.GetLightmapTextureIndices(rendererData, lightMapTextureIndices);
                    Profiler.EndSample();
                }
                Profiler.EndSample();

                // --------------------------------------------------------------------------------------------------------------------------------------
                // Allocate and Update CPU instance data
                // --------------------------------------------------------------------------------------------------------------------------------------
                var instances = new NativeArray<InstanceHandle>(rendererData.localToWorldMatrix.Length, Allocator.TempJob, NativeArrayOptions.UninitializedMemory);

                Profiler.BeginSample("AllocateInstanceData");
                {
                    m_BatchersContext.ReallocateAndGetInstances(rendererData, instances);
                    var updateInstanceDataJob = m_BatchersContext.ScheduleUpdateInstanceDataJob(instances, rendererData);

                    GPUInstanceDataBufferUploader uploader = m_BatchersContext.CreateDataBufferUploader(instances.Length, InstanceType.MeshRenderer);
                    uploader.AllocateUploadHandles(instances.Length);
                    JobHandle writeJobHandle = default;
                    writeJobHandle = uploader.WriteInstanceDataJob(m_BatchersContext.renderersParameters.lightmapIndex.index, lightMapTextureIndices, rendererData.rendererGroupIndex);
                    writeJobHandle = JobHandle.CombineDependencies(uploader.WriteInstanceDataJob(m_BatchersContext.renderersParameters.lightmapScale.index, rendererData.lightmapScaleOffset, rendererData.rendererGroupIndex), writeJobHandle);

                    writeJobHandle.Complete();

                    m_BatchersContext.SubmitToGpu(instances, ref uploader, submitOnlyWrittenParams: true);
                    m_BatchersContext.ChangeInstanceBufferVersion();
                    lightMapTextureIndices.Dispose();
                    uploader.Dispose();

                    // --------------------------------------------------------------------------------------------------------------------------------------
                    // Update and Upload Transform data to GPU
                    // ----------------------------------------------------------------------------------------------------------------------------------
                    updateInstanceDataJob.Complete();
                    m_BatchersContext.InitializeInstanceTransforms(instances, rendererData.localToWorldMatrix, rendererData.prevLocalToWorldMatrix);

                }
                Profiler.EndSample();

                // --------------------------------------------------------------------------------------------------------------------------------------
                // Instance culling batcher
                // --------------------------------------------------------------------------------------------------------------------------------------

                Profiler.BeginSample("InstanceCullingBatcher.BuildBatch");
                {
                    m_InstanceCullingBatcher.BuildBatch(
                        instances,
                        usedMaterialIDs.AsArray(),
                        rendererData.meshID,
                        rendererToMaterialMap,
                        rendererData);

                }
                Profiler.EndSample();

                instances.Dispose();
                usedMaterialIDs.Dispose();
            }
            Profiler.EndSample();
        }

        private void OnFinishedCulling(IntPtr customCullingResult)
        {
            ProcessTrees();
            m_InstanceCullingBatcher.OnFinishedCulling(customCullingResult);
        }
    }
}

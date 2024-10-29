using System.Collections;
using System.Collections.Generic;
using UnityEditor;

using UnityEngine;

public class BuildBenchmark
{
    [MenuItem("Meta/Build Benchmark Project")]
    static void BuildProject()
    {
        EditorUserBuildSettings.SwitchActiveBuildTarget(BuildTargetGroup.Android, BuildTarget.Android);
        PlayerSettings.SetApplicationIdentifier(BuildTargetGroup.Android, "com.meta.performancebenchmark");
        BuildPipeline.BuildPlayer(new string[] { "Assets/Scenes/Garden/GardenScene.unity" }, "VulkanPerformanceBenchmark.apk", BuildTarget.Android, BuildOptions.None);
    }
}

#!/usr/bin/env python3
"""Generate a deterministic, dependency-free framework wrapper for xcodebuild.

The SwiftPM source target remains authoritative. The wrapper compiles precisely
its sorted Swift files; it has no app resources, entitlements or signing inputs.
Generated project files belong under build/ and are not source deliverables.
"""
from __future__ import annotations
import hashlib
import os
from pathlib import Path
import plistlib
import sys
import xml.etree.ElementTree as ET


def generate(root: Path, output: Path) -> Path:
    root, output = root.resolve(), output.resolve()
    files = sorted((root / "Sources/Switch2Kit").rglob("*.swift"))
    if not files:
        raise SystemExit("No Switch2Kit sources found")
    project = output / "Switch2Kit.xcodeproj"
    project.mkdir(parents=True, exist_ok=True)
    objects: dict[str, dict] = {}

    def add(key: str, isa: str, **values: object) -> str:
        identity = hashlib.sha256(key.encode()).hexdigest()[:24].upper()
        if identity in objects:
            raise ValueError(f"Duplicate project object: {key}")
        objects[identity] = {"isa": isa, **values}
        return identity

    references, sources = [], []
    for file in files:
        relative = file.relative_to(root).as_posix()
        reference = add("file:" + relative, "PBXFileReference", lastKnownFileType="sourcecode.swift",
                        path=os.path.relpath(file, output), sourceTree="SOURCE_ROOT")
        references.append(reference)
        sources.append(add("build:" + relative, "PBXBuildFile", fileRef=reference))
    source_group = add("sources", "PBXGroup", name="Switch2Kit Sources", children=references, sourceTree="<group>")
    product = add("framework", "PBXFileReference", explicitFileType="wrapper.framework", includeInIndex=0,
                  path="Switch2Kit.framework", sourceTree="BUILT_PRODUCTS_DIR")
    products = add("products", "PBXGroup", name="Products", children=[product], sourceTree="<group>")
    main_group = add("main", "PBXGroup", children=[source_group, products], sourceTree="<group>")
    compile_phase = add("compile", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=sources,
                        runOnlyForDeploymentPostprocessing=0)
    link_phase = add("link", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[],
                     runOnlyForDeploymentPostprocessing=0)
    project_settings = {
        "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "15.0", "SWIFT_VERSION": "6.0",
        "CLANG_ENABLE_MODULES": "YES", "SUPPORTED_PLATFORMS": "macosx",
    }
    target_settings = {
        "PRODUCT_NAME": "Switch2Kit", "PRODUCT_BUNDLE_IDENTIFIER": "org.switch2kit.framework",
        "DEFINES_MODULE": "YES", "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES", "SKIP_INSTALL": "NO",
        "GENERATE_INFOPLIST_FILE": "YES", "FRAMEWORK_VERSION": "A", "CURRENT_PROJECT_VERSION": "1",
        "MARKETING_VERSION": "0.0.0", "INSTALL_PATH": "$(LOCAL_LIBRARY_DIR)/Frameworks",
        "DYLIB_INSTALL_NAME_BASE": "@rpath", "MACH_O_TYPE": "mh_dylib",
        "CODE_SIGNING_ALLOWED": "NO", "CODE_SIGN_IDENTITY": "", "CODE_SIGNING_REQUIRED": "NO",
        "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "NO", "ONLY_ACTIVE_ARCH": "NO",
        "SWIFT_OPTIMIZATION_LEVEL": "-O", "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_STRICT_CONCURRENCY": "complete", "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
        "OTHER_SWIFT_FLAGS": "$(inherited) -package-name Switch2Kit",
        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "DEAD_CODE_STRIPPING": "YES",
    }

    def configurations(prefix: str, settings: dict) -> str:
        release = add(prefix + ":release", "XCBuildConfiguration", name="Release", buildSettings=settings)
        return add(prefix + ":configs", "XCConfigurationList", buildConfigurations=[release],
                   defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

    target = add("target", "PBXNativeTarget", name="Switch2Kit", productName="Switch2Kit",
                 productType="com.apple.product-type.framework", productReference=product,
                 buildConfigurationList=configurations("target", target_settings),
                 buildPhases=[compile_phase, link_phase], buildRules=[], dependencies=[])
    project_id = add("project", "PBXProject", attributes={"LastUpgradeCheck": "2600"},
                     buildConfigurationList=configurations("project", project_settings),
                     compatibilityVersion="Xcode 14.0", developmentRegion="en", knownRegions=["en", "Base"],
                     mainGroup=main_group, productRefGroup=products, projectDirPath="", projectRoot="",
                     targets=[target])
    # project.pbxproj is a property list. XML avoids ambiguous OpenStep quoting.
    with (project / "project.pbxproj").open("wb") as handle:
        plistlib.dump({"archiveVersion": "1", "classes": {}, "objectVersion": "56",
                      "objects": objects, "rootObject": project_id}, handle, sort_keys=True)
    scheme = ET.Element("Scheme", LastUpgradeVersion="2600", version="1.7")
    build = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
    entry = ET.SubElement(ET.SubElement(build, "BuildActionEntries"), "BuildActionEntry",
                          buildForTesting="YES", buildForRunning="YES", buildForProfiling="YES",
                          buildForArchiving="YES", buildForAnalyzing="YES")
    ET.SubElement(entry, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=target,
                  BuildableName="Switch2Kit.framework", BlueprintName="Switch2Kit",
                  ReferencedContainer="container:Switch2Kit.xcodeproj")
    ET.SubElement(scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="NO")
    schemes = project / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    ET.indent(scheme)
    ET.ElementTree(scheme).write(schemes / "Switch2Kit.xcscheme", encoding="utf-8", xml_declaration=True)
    return project


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: generate-framework-project.py REPOSITORY_ROOT OUTPUT_DIRECTORY")
    print(generate(Path(sys.argv[1]), Path(sys.argv[2])))

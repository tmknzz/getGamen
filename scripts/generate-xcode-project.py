from pathlib import Path
import hashlib
import os
import json

os.chdir(Path(__file__).resolve().parent.parent)
Path("getGamen.xcodeproj/xcshareddata/xcschemes").mkdir(parents=True, exist_ok=True)

def uid(s): return hashlib.sha256(s.encode()).hexdigest()[:24].upper()
objects=[]
def obj(k,v): objects.append(f'{uid(k)} = {{ {v} }};'); return uid(k)
def refs(keys): return '('+','.join(uid(k) for k in keys)+',)'
sourceKeys=[]; sourceBuild=[]
for path in sorted(Path('Sources/GetGamen').glob('*.swift')):
    key=str(path); sourceKeys.append(key); sourceBuild.append('build:'+key)
    obj(key,f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{key}"; sourceTree = SOURCE_ROOT;')
    obj('build:'+key,f'isa = PBXBuildFile; fileRef = {uid(key)};')
icon='App/AppIcon.icns'
obj(icon,f'isa = PBXFileReference; lastKnownFileType = image.icns; path = "{icon}"; sourceTree = SOURCE_ROOT;')
obj('build:'+icon,f'isa = PBXBuildFile; fileRef = {uid(icon)};')
sounds=['App/Sounds/Shutter.wav','App/Sounds/Shutter-LICENSE.txt']
for path,ftype in zip(sounds,['audio.wav','text']):
    obj(path,f'isa = PBXFileReference; lastKnownFileType = {ftype}; path = "{path}"; sourceTree = SOURCE_ROOT;')
    obj('build:'+path,f'isa = PBXBuildFile; fileRef = {uid(path)};')
obj('app-resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {refs(["build:"+icon]+["build:"+p for p in sounds])}; runOnlyForDeploymentPostprocessing = 0;')
ui='UITests/GetGamenUITests.swift'
obj(ui,f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{ui}"; sourceTree = SOURCE_ROOT;')
obj('build:'+ui,f'isa = PBXBuildFile; fileRef = {uid(ui)};')
obj('app-product','isa = PBXFileReference; explicitFileType = wrapper.application; path = getGamen.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('ui-product','isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = GetGamenUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
obj('root-group',f'isa = PBXGroup; children = {refs(sourceKeys+[icon]+sounds+[ui,"products"])}; sourceTree = "<group>";')
obj('products',f'isa = PBXGroup; children = {refs(["app-product","ui-product"])}; name = Products; sourceTree = "<group>";')
obj('package','isa = XCLocalSwiftPackageReference; relativePath = .;')
obj('core-product',f'isa = XCSwiftPackageProductDependency; package = {uid("package")}; productName = GetGamenCore;')
obj('core-build',f'isa = PBXBuildFile; productRef = {uid("core-product")};')
obj('app-sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(sourceBuild)}; runOnlyForDeploymentPostprocessing = 0;')
obj('ui-sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(["build:"+ui])}; runOnlyForDeploymentPostprocessing = 0;')
obj('frameworks',f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {refs(["core-build"])}; runOnlyForDeploymentPostprocessing = 0;')
stamp_script = 'python3 "$SRCROOT/scripts/stamp-build.py" "$SRCROOT/App/Info.plist" "$DERIVED_FILE_DIR/getGamen-Info.plist"'
obj('build-number', 'isa = PBXShellScriptBuildPhase; alwaysOutOfDate = 1; buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = ("$(DERIVED_FILE_DIR)/getGamen-Info.plist",); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = '+json.dumps(stamp_script)+';')
helper_script = 'cd "$SRCROOT"\nswift build --scratch-path .build/xcode-automation -c release --arch arm64 --arch x86_64 --product getGamenAutomation -Xswiftc -warnings-as-errors >&2\nbin_dir="$(swift build --scratch-path .build/xcode-automation -c release --arch arm64 --arch x86_64 --show-bin-path)"\npython3 scripts/bundle-automation-helper.py "$bin_dir/getGamenAutomation" "$TARGET_BUILD_DIR/$WRAPPER_NAME" "$DERIVED_FILE_DIR/getGamen-Info.plist"'
obj('automation-helper', 'isa = PBXShellScriptBuildPhase; alwaysOutOfDate = 1; buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = (); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/bash; shellScript = '+json.dumps('set -euo pipefail\n'+helper_script)+';')
obj('dependency',f'isa = PBXTargetDependency; target = {uid("app")};')
for target in ['project','app','ui']:
    for config in ['Debug','Release']:
        settings='SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 14.0; SWIFT_VERSION = 5.0; CLANG_ENABLE_MODULES = YES; SWIFT_TREAT_WARNINGS_AS_ERRORS = YES;'
        if config=='Debug': settings+=' SWIFT_OPTIMIZATION_LEVEL = "-Onone"; ENABLE_TESTABILITY = YES; DEBUG_INFORMATION_FORMAT = dwarf; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;'
        if target=='app': settings+=' PRODUCT_NAME = getGamen; PRODUCT_BUNDLE_IDENTIFIER = com.tmknzz.getGamen; INFOPLIST_FILE = "$(DERIVED_FILE_DIR)/getGamen-Info.plist"; ENABLE_USER_SCRIPT_SANDBOXING = NO; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual;'
        if target=='ui': settings+=' PRODUCT_NAME = GetGamenUITests; PRODUCT_BUNDLE_IDENTIFIER = com.tmknzz.getGamen.UITests; GENERATE_INFOPLIST_FILE = YES; TEST_TARGET_NAME = GetGamenDesktop; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual;'
        obj(target+config,f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{ {settings} }};')
    obj(target+'-configs',f'isa = XCConfigurationList; buildConfigurations = {refs([target+"Debug",target+"Release"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('app',f'isa = PBXNativeTarget; name = GetGamenDesktop; productName = getGamen; productReference = {uid("app-product")}; productType = "com.apple.product-type.application"; buildConfigurationList = {uid("app-configs")}; buildPhases = {refs(["build-number","app-sources","frameworks","app-resources","automation-helper"])}; buildRules = (); dependencies = (); packageProductDependencies = {refs(["core-product"])};')
obj('ui',f'isa = PBXNativeTarget; name = GetGamenUITests; productName = GetGamenUITests; productReference = {uid("ui-product")}; productType = "com.apple.product-type.bundle.ui-testing"; buildConfigurationList = {uid("ui-configs")}; buildPhases = {refs(["ui-sources"])}; buildRules = (); dependencies = {refs(["dependency"])};')
obj('project',f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {uid("project-configs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = ja; knownRegions = (ja,en,Base); mainGroup = {uid("root-group")}; productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; targets = {refs(["app","ui"])}; packageReferences = {refs(["package"])};')
Path('getGamen.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {uid("project")}; }}\n')
ref=lambda target,product,name: f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(target)}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:getGamen.xcodeproj"/>'
app=ref('app','getGamen.app','GetGamenDesktop');ui=ref('ui','GetGamenUITests.xctest','GetGamenUITests')
Path('getGamen.xcodeproj/xcshareddata/xcschemes/getGamen.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ui}</TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')

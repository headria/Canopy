#!/usr/bin/env python3
"""Generate the checked-in native app/static core Xcode project; no dependencies."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
objects = {}

def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def add(object_name, **values):
    key = uid(object_name)
    objects[key] = values
    return key

def group_sources(module):
    children, builds = [], []
    directory = ROOT / 'Sources' / module
    for path in sorted(directory.rglob('*.swift')):
        ref = add(str(path.relative_to(ROOT)), isa='PBXFileReference', lastKnownFileType='sourcecode.swift',
                  path=str(path.relative_to(directory)), sourceTree='<group>')
        children.append(ref)
        builds.append(add('build:' + str(path.relative_to(ROOT)), isa='PBXBuildFile', fileRef=ref))
    return add(module + ':group', isa='PBXGroup', children=children, path='Sources/' + module, sourceTree='<group>'), builds

core_group, core_sources = group_sources('CanopyCore')
app_group, app_sources = group_sources('CanopyApp')
resource_refs, resource_builds = [], []
for name in ('StoreInfo.plist', 'AppStore.entitlements', 'PrivacyInfo.xcprivacy', 'PrivacyPolicy.txt', '../StoreAssets/Canopy.icns', 'NoteEditor'):
    file_type = 'folder' if name == 'NoteEditor' else 'image.icns' if name.endswith('.icns') else 'text.xml' if name.endswith('.xcprivacy') else 'text.plist.entitlements' if name.endswith('.entitlements') else 'text.plist.xml' if name.endswith('.plist') else 'text'
    ref = add('resource:' + name, isa='PBXFileReference', path=name, sourceTree='<group>', lastKnownFileType=file_type)
    resource_refs.append(ref)
    if name not in ('StoreInfo.plist', 'AppStore.entitlements'):
        resource_builds.append(add('resourcebuild:' + name, isa='PBXBuildFile', fileRef=ref))
resources_group = add('resources:group', isa='PBXGroup', children=resource_refs, path='Resources', sourceTree='<group>')
config = add('store:config', isa='PBXFileReference', lastKnownFileType='text.xcconfig', path='Store/Store.xcconfig', sourceTree='<group>')
core_product = add('core:product', isa='PBXFileReference', explicitFileType='archive.ar', path='libCanopyCore.a', sourceTree='BUILT_PRODUCTS_DIR')
app_product = add('app:product', isa='PBXFileReference', explicitFileType='wrapper.application', path='Canopy.app', sourceTree='BUILT_PRODUCTS_DIR')
products = add('products:group', isa='PBXGroup', children=[core_product, app_product], name='Products', sourceTree='<group>')
main_group = add('main:group', isa='PBXGroup', children=[core_group, app_group, resources_group, config, products], sourceTree='<group>')

def phase(name, isa, files):
    return add(name, isa=isa, buildActionMask=2147483647, files=files, runOnlyForDeploymentPostprocessing=0)

core_phase = phase('core:sources', 'PBXSourcesBuildPhase', core_sources)
app_phase = phase('app:sources', 'PBXSourcesBuildPhase', app_sources)
resource_phase = phase('app:resources', 'PBXResourcesBuildPhase', resource_builds)
core_link = add('core:link', isa='PBXBuildFile', fileRef=core_product)
link_phase = phase('app:frameworks', 'PBXFrameworksBuildPhase', [core_link])
release_check = add('app:releasecheck', isa='PBXShellScriptBuildPhase', buildActionMask=2147483647,
    files=[], inputPaths=['$(SRCROOT)'], outputPaths=[], runOnlyForDeploymentPostprocessing=0,
    name='Validate Store archive configuration', shellPath='/bin/sh', shellScript='''if [ "$ACTION" = install ]; then
  if [ "$CANOPY_UPLOAD_CANDIDATE" = YES ]; then
    CANOPY_TEAM_ID="$DEVELOPMENT_TEAM" /usr/bin/python3 "$SRCROOT/scripts/check-store-readiness.py" --upload-candidate-config
  else
    CANOPY_TEAM_ID="$DEVELOPMENT_TEAM" /usr/bin/python3 "$SRCROOT/scripts/check-store-readiness.py" --release-config
  fi
fi
''')

def configs(name, settings, base=None):
    children = []
    for configuration in ('Debug', 'Release'):
        values = dict(settings)
        if configuration == 'Debug':
            values.update(SWIFT_OPTIMIZATION_LEVEL='-Onone', ONLY_ACTIVE_ARCH='YES')
        else:
            values.update(SWIFT_OPTIMIZATION_LEVEL='-O', ONLY_ACTIVE_ARCH='NO', DEBUG_INFORMATION_FORMAT='dwarf-with-dsym')
        obj = dict(isa='XCBuildConfiguration', buildSettings=values, name=configuration)
        if base: obj['baseConfigurationReference'] = base
        children.append(add(name + ':' + configuration, **obj))
    return add(name + ':configlist', isa='XCConfigurationList', buildConfigurations=children, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')

project_configs = configs('project', {'SDKROOT': 'macosx', 'MACOSX_DEPLOYMENT_TARGET': '26.0',
    'SWIFT_VERSION': '5.0', 'CLANG_ENABLE_MODULES': 'YES', 'ARCHS': '$(ARCHS_STANDARD)'})
core_configs = configs('core', {'PRODUCT_NAME': 'CanopyCore', 'PRODUCT_MODULE_NAME': 'CanopyCore',
    'DEFINES_MODULE': 'YES', 'SKIP_INSTALL': 'YES', 'CODE_SIGNING_ALLOWED': 'NO', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': '$(inherited) CANOPY_APP_STORE'})
app_configs = configs('app', {'PRODUCT_MODULE_NAME': 'CanopyApp', 'SKIP_INSTALL': 'NO',
    'SWIFT_INCLUDE_PATHS': '$(inherited) $(BUILT_PRODUCTS_DIR)',
    'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/../Frameworks'}, config)
core_target = add('core:target', isa='PBXNativeTarget', buildConfigurationList=core_configs,
    buildPhases=[core_phase], buildRules=[], dependencies=[], name='CanopyCore', productName='CanopyCore',
    productReference=core_product, productType='com.apple.product-type.library.static')
proxy = add('core:proxy', isa='PBXContainerItemProxy', containerPortal=uid('project'), proxyType=1,
    remoteGlobalIDString=core_target, remoteInfo='CanopyCore')
dependency = add('core:dependency', isa='PBXTargetDependency', target=core_target, targetProxy=proxy)
app_target = add('app:target', isa='PBXNativeTarget', buildConfigurationList=app_configs,
    buildPhases=[release_check, app_phase, link_phase, resource_phase], buildRules=[], dependencies=[dependency],
    name='CanopyAppStore', productName='Canopy', productReference=app_product, productType='com.apple.product-type.application')
project = add('project', isa='PBXProject', attributes={'LastUpgradeCheck': '2600',
    'TargetAttributes': {app_target: {'CreatedOnToolsVersion': '26.0', 'SystemCapabilities': {
        'com.apple.Sandbox': {'enabled': 1}, 'com.apple.HardenedRuntime': {'enabled': 1}}}}},
    buildConfigurationList=project_configs, compatibilityVersion='Xcode 14.0', developmentRegion='en',
    hasScannedForEncodings=0, knownRegions=['en', 'Base'], mainGroup=main_group,
    productRefGroup=products, projectDirPath='', projectRoot='', targets=[core_target, app_target])

def serialize(value, depth=0):
    tab = '\t' * depth
    if isinstance(value, dict):
        return '{\n' + ''.join('\t' * (depth+1) + json.dumps(k) + ' = ' + serialize(v, depth+1) + ';\n' for k,v in value.items()) + tab + '}'
    if isinstance(value, list):
        return '(\n' + ''.join('\t' * (depth+1) + serialize(v, depth+1) + ',\n' for v in value) + tab + ')'
    return str(value) if isinstance(value, int) else json.dumps(value)

directory = ROOT / 'Canopy.xcodeproj'
directory.mkdir(exist_ok=True)
data = {'archiveVersion': 1, 'classes': {}, 'objectVersion': 56, 'objects': objects, 'rootObject': project}
(directory / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + serialize(data) + '\n')
schemes = directory / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="Canopy.app" BlueprintName="CanopyAppStore" ReferencedContainer="container:Canopy.xcodeproj"/>'
(schemes / 'CanopyAppStore.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print('Generated Canopy.xcodeproj with CanopyAppStore and CanopyCore targets.')

#!/bin/bash
# Filter xcodebuild output: drop per-file compile/link chatter, keep errors,
# warnings, build/test summary lines, and per-test pass/fail.
#
# If xcpretty is installed, use it. Otherwise fall back to the awk filter below.

set -o pipefail

if command -v xcpretty >/dev/null 2>&1; then
  exec xcpretty --color
fi

exec awk '
# --- Multi-line block skipping (Entitlements, Build settings, etc.)
in_block && /^[[:space:]]*}[[:space:]]*$/ { in_block = 0; next }
in_block                                   { next }
/^[[:space:]]*Entitlements:[[:space:]]*$/  { in_block = 1; next }
/^[[:space:]]*Build settings for action build:[[:space:]]*$/ { next }

# --- Drop asset catalog / actool compilation-results block:
#     /* com.apple.actool.compilation-results */
#     <path>
#     <path>
#     ...
in_actool_block && /^\/\*/ { in_actool_block = 0 }  # next marker block starts
in_actool_block && /^\// { next }                   # path line, drop
/^\/\* com\.apple\.actool\.compilation-results \*\// { in_actool_block = 1; next }

# --- Build-phase keywords followed by path (bulk of xcodebuild noise)
/^(CompileSwift|CompileC|CompileStoryboard|CompileXIB|CompileAssetCatalog|CopyPlistFile|CopyStringsFile|CopySwiftLibs|CpResource|CreateBuildDirectory|CreateUniversalBinary|DataModelCompile|EmitSwiftModule|ExtractAppIntentsMetadata|ExtractAppShortcutStringsMetadata|ExtractDocumentationComments|GenerateAssetSymbols|GenerateDSYMFile|GenerateTextureAtlas|Ld |Libtool |LinkAssetCatalog|MergeSwiftModule|MkDir |PBXCp|PhaseScriptExecution|Processing |ProcessInfoPlistFile|ProcessIntentsMetadata|ProcessProductPackaging|ProcessProductPackagingDER|RegisterExecutionPolicyException|RegisterWithLaunchServices|ReplaceDeviceSupportVersions|RuleScriptExecution|ScanDependencies|SignDocument|Strip |SwiftBuildModule|SwiftCompile|SwiftDriver|SwiftDriverJobDiscovery|SwiftEmit|SwiftMergeGeneratedHeaders|SymLink |Touch |ValidateDevelopmentEntitlements|ValidateEmbeddedBinary|ValidateEntitlements|WriteAuxiliaryFile|CodeSign |Copy |Validate |ExecuteExternalTool |ClangStatCache )/ { next }

# --- Build orchestration events (single-word lines)
/^(ComputePackagePrebuildTargetDependencyGraph|CreateBuildRequest|SendProjectDescription|CreateBuildOperation|ComputeTargetDependencyGraph|GatherProvisioningInputs|CreateBuildDescription)$/ { next }

# --- Headers and setup chatter
/^Command line invocation:/          { next }
/^Build settings from command line:/ { next }
/^Build description (signature|path):/ { next }
/^Resolve Package Graph/             { next }
/^Resolved source packages:/         { next }
/^Fetching /                         { next }
/^Prepare packages/                  { next }
/^Prepare build/                     { next }
/^Indexing /                         { next }
/^Computing target dependency graph/ { next }

# --- Top-level "note:" lines and target graph indentation
/^note: /                            { next }
/^[[:space:]]+Target .* in project .*/ { next }
/^[[:space:]]+➜ /                    { next }

# --- Indented subprocess context, write-file lines, and misc
/^[[:space:]]+write-file /                                                   { next }
/^[[:space:]]+(export |cd |builtin-|setenv |\/Applications\/Xcode|\/usr\/bin\/|\/bin\/|\/usr\/libexec\/|\/System\/Library\/)/ { next }
/^[[:space:]]+SYMROOT = /                                                    { next }
/^[[:space:]]+Signing Identity:/                                             { next }
/^\{ platform:/                                                              { next }

# --- Codesign informational lines
/: replacing existing signature$/                                            { next }

# --- Subprocess helper tools that log date-prefixed lines
/^[0-9]{4}-[0-9]{2}-[0-9]{2} .* (appintentsmetadataprocessor|actool|ibtool|ibtoold|intentbuilderc)\[/ { next }

# --- Blank/whitespace-only lines
/^[[:space:]]*$/ { next }

{ print }
'

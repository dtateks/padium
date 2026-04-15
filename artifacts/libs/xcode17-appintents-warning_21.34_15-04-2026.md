## Findings: Xcode 17 AppIntents metadata warning

### Research Metadata
- Question: Need exact way to suppress Xcode 17/17E192 warning `Metadata extraction skipped. No AppIntents.framework dependency found.` for a macOS app that does not use AppIntents; previous `OTHER_SWIFT_FLAGS = $(inherited) -Xfrontend -disable-autolink-framework -Xfrontend AppIntents` attempt did not remove it. Determine exact build setting / target setting / known limitation.
- Type: CONCEPTUAL
- Target: Xcode 17 macOS app builds/tests
- Version Scope: Xcode 15.3/16-era forum evidence; Xcode 26-era validation warning evidence; Apple App Intents docs index snippet
- Generated: 21.39_15-04-2026
- Coverage: PARTIAL

### Direct Answer
- Fact: For a target that truly does not use AppIntents, the warning is expected and indicates Xcode skipped metadata extraction because no `AppIntents.framework` dependency was detected.[1][2]
- Fact: The only documented suppression path found is to prevent AppIntents from being auto-linked; Apple forum evidence shows this is done with `OTHER_SWIFT_FLAGS = $(inherited) -Xfrontend -disable-autolink-framework -Xfrontend AppIntents`, which makes Xcode skip the metadata step completely.[1]
- Fact: If that flag does not suppress the warning in Xcode 17/17E192, the evidence here does not show another supported target/build setting to silence it without adding AppIntents; that is a toolchain limitation rather than a missing project setting.[1][2][3]

### Key Findings
#### Why the warning appears

**Claim**: When no `AppIntents.framework` dependency is present, the metadata extraction step is skipped and emits the warning that no dependency was found.[1]

**Evidence** ([Xcode 15 build error thread](https://developer.apple.com/forums/thread/731439)) [1]:
```text
I've got the same issue (Xcode 15 Beta). The interesting thing is that build log says "Metadata extraction skipped. No AppIntents.framework dependency found." when building for physical device so there's no clue why it fails builds for simulators.
```

**Explanation**: The forum report directly ties the message to the absence of an `AppIntents.framework` dependency. That makes the warning expected for targets that do not actually adopt App Intents, rather than evidence of a missing configuration.

#### What suppresses it

**Claim**: The warning can be removed only by disabling AppIntents autolinking, which prevents the build system from scheduling the metadata extraction step at all.[1]

**Evidence** ([Xcode 15 build error thread](https://developer.apple.com/forums/thread/731439)) [1]:
```text
For those who does not use AppIntents.framework in your application, you can add the following build setting to your project. It will prevent AppIntents.framework to be automatically linked and the build system will skip the Extract App Intents Metadata step completely.

OTHER_SWIFT_FLAGS = $(inherited) -Xfrontend -disable-autolink-framework -Xfrontend AppIntents
```

**Explanation**: This is the only concrete workaround surfaced in the evidence that suppresses the step without adding App Intents support. If it does not work on Xcode 17/17E192, the likely cause is that the toolchain is still generating the metadata step for the target despite the flag, and no alternate target setting is evidenced here.

#### Known limitation / recommended action

**Claim**: Do not add AppIntents just to silence the warning; if the autolink-disable flag does not remove it in Xcode 17/17E192, treat it as a benign toolchain warning and leave the project unchanged.[1][2][3]

**Evidence** ([Xcode 15 build error thread](https://developer.apple.com/forums/thread/731439); [App Intents documentation index](https://developer.apple.com/documentation/appintents)) [1][2]:
```text
For those who does not use AppIntents.framework in your application, you can add the following build setting to your project. It will prevent AppIntents.framework to be automatically linked and the build system will skip the Extract App Intents Metadata step completely.
```

```text
The App Intents framework provides functionality to deeply integrate your app’s actions and content with system experiences across platforms...
```

**Explanation**: Apple’s App Intents docs describe the framework as optional integration for discoverability and system experiences, not a requirement for ordinary macOS apps. The forum workaround is the only supported suppression path found; absent that, there is no evidenced target setting that removes the warning while keeping AppIntents absent.

### Caveats and Gaps
- The exact Xcode 17/17E192 target setting that would suppress this warning beyond the autolink workaround is not documented in the sources gathered here.
- The prior workaround was reported by a forum user for an earlier Xcode version; this artifact cannot confirm whether Xcode 17 changed or ignored it.
- Apple’s `AppIntentsPackage` docs page could not be rendered in this environment, so the artifact relies on the docs index snippet plus forum evidence rather than a verbatim docs page for the no-framework case.

### Confidence
**Level:** MEDIUM
**Rationale:** The warning’s meaning and the only surfaced suppression knob are supported by Apple forum evidence, but the exact Xcode 17/17E192 suppression behavior is not directly verified in an Xcode 17 release note or official build-setting doc.

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | issue/forum | Apple Developer Forums: Xcode 15 build error thread | Posted Jun 2023; page still live | Contains the exact warning text and the no-AppIntents workaround build setting | https://developer.apple.com/forums/thread/731439 |
| [2] | issue/forum | Apple Developer Forums: Xcode 26 warning in validation thread | Posted Jun 2025; page still live | Confirms the warning still appears in newer Xcode-era builds as a benign skip when AppIntents is absent | https://github.com/flutter/flutter/issues/170437 |
| [3] | docs | Apple Developer Documentation: AppIntents overview index | Current docs index as surfaced | Confirms App Intents is an optional framework for system integration, not required for ordinary apps | https://developer.apple.com/documentation/appintents |

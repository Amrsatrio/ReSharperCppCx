# ReSharper C++/CX

A mod for ReSharper C++ that adds C++/CX analysis support, building atop the existing C++/CLI support. Provides an unofficial implementation of the functionality requested in [RSCPP-10943](https://youtrack.jetbrains.com/issue/RSCPP-10943/support-C-CX-platform).

## Background

[ReSharper C++ 2018.2 introduced C++/CLI support](https://blog.jetbrains.com/rscpp/2018/09/12/whats-new-in-resharper-cpp-2018-2/) with a managed C++ parser, type system, code analysis, completion, and navigation. Current Rider builds (2026.x at the time of writing) also recognize `/ZW` projects as the distinct `CppCx` dialect, but stop before normal analysis and leave many shared paths restricted to `CppCli`.

This mod keeps C++/CX separate from C++/CLI while reusing JetBrains' managed C++ implementation where the languages agree. It enables the existing `CppCx` pipeline and adds the Windows Runtime projections and semantics that differ from C++/CLI. Credit for the managed C++ foundation belongs to JetBrains.

## How to?

> [!NOTE]
> Only Windows is supported by the tooling provided in this repository.

### Automatic installation

> [!NOTE]
> Only JetBrains Rider is supported for automatic installation. If you're using ReSharper C++ outside of Rider, please see the [Manual installation](#manual-installation) section.

#### Prerequisites

1. A supported Windows version of JetBrains Rider is installed and normally activated under your own valid JetBrains license.
   - A current non-commercial, individual, or organization license is required as applicable to your use.
   - Both standalone installer and Toolbox installations are supported.
1. Visual Studio (or its standalone Build Tools) with these installed:
   - "Desktop development with .NET" workload
   - ".NET Framework 4.8 development tools" optional component
1. .NET SDK 10 or newer.
1. If you're using JetBrains Toolbox, disable automatic updates for Rider.

#### Installing

1. Clone this repository.
   ```cmd
   git clone https://github.com/Amrsatrio/ReSharperCppCx
   ```
1. Close all instances of Rider.
1. Run `Install.bat`.
1. Pick your Rider installation.
1. Confirm installation of the mod by selecting `Install C++/CX support`.
1. Wait until it's done.
1. Load your C++/CX project. Done!

#### Uninstalling

> [!WARNING]
> Please be sure to uninstall the mod before updating Rider to avoid installation issues, since updates rely on delta patching.

1. Run `Install.bat`.
1. Pick your Rider installation that says `[Patched]`.
1. Uninstall the mod by selecting `Restore original DLLs`.

#### Updating

1. Update your local copy of this repository. For example, using Git CLI:
   ```cmd
   git pull
   ```
1. Close all instances of Rider.
1. Run `Install.bat`.
1. Pick your Rider installation that says `[Patched]`.
1. Select `Update C++/CX support` and confirm the update.
1. Wait for the updated patches to be applied, built, and installed.
1. Reopen your C++/CX project. Done!

### Manual installation

Use this flow if you're using ReSharper C++ outside JetBrains Rider (e.g. ReSharper C++ Visual Studio extension or ReSharper command-line tools).

1. Determine your ReSharper C++ version.
1. If you're using ReSharper C++ Visual Studio extension, close all instances of Visual Studio.
1. Run `Install.bat`.
1. Pick `Customize / online version`.
1. Pick `[O]nline`.
1. Follow the prompts to select your version.
1. Pick `[A]uto` patches.
1. Pick `[B]uild` finishing.
1. Wait until it's done. Once done, built modded DLLs will be located in `<repo root>/Work/<version>_<build>/Build/Release`.
1. Locate the locations of those DLLs in your ReSharper C++ installation.
1. Backup the original DLLs by renaming them to `<name>.bak.dll`.
1. Copy the modded DLLs to the ReSharper C++ installation folder.
1. Load your C++/CX project. Done!

## Supported ReSharper C++ versions

| Version              | Supported     |
|----------------------|---------------|
| 2025.3.x and earlier | ❌             |
| 2026.1.x             | ✅<sup>1</sup> |
| 2026.2.x             | ✅<sup>1</sup> |
| 2026.3.x and newer   | ❌<sup>2</sup> |

1. Patches are authored against the initial build of each quarterly release and generally apply to all subsequent builds in that release (for example, 2026.1 patches apply to 2026.1.5.2). If a later build fails to apply, please report it as an issue.
1. Quarterly releases introduce breaking changes compared to the previous release, so porting work is required before they can be supported.

## What the mod does

### Language engine repairs: `JetBrains.ReSharper.Cpp.dll`

This DLL contains the parser, PSI, metadata projection, type system, and resolver changes:

| Area | ReSharper C++ | C++/CX patch |
|------|---------------|--------------|
| Language pipeline | Detects `/ZW` as the distinct `CppCx` language kind. The lexer and [PSI](https://www.jetbrains.com/help/resharper/sdk/PSI_Overview.html) (Program Structure Interface) already model managed class keys, handles (`^`), tracking references (`%`), properties, events, delegates, and metadata-backed entities shared with C++/CLI. | Removes the "unsupported dialect" analysis blocker, enables shared parser and resolver paths for `CppCx`, and adds `ref new`, `partial`, `__cplusplus_winrt`, metadata attributes, and WinRT builtins. |
| Metadata and types | Provides CLR symbol scopes, managed metadata import, type conversion, and overload resolution. | Adds evaluated `/FU` WinMD references and C++/CX projections for `Platform` types, WinRT runtime classes, interfaces, enums, value types, arrays, and signatures. |
| Semantics | Provides managed handles, boxing infrastructure, properties, events, generated members, and delegates for C++/CLI. | Adds `Platform` roots, WinRT boxing and casts, event tokens, delegate callback contexts, value class rules, collection projections, handle/value conversions, and MSVC-specific overload behavior. |

#### Notable compatibility repairs

**Projected members on primitives, enums, and value types**

C++/CX supports managed member calls on primitive, enum, and value operands, including `const` values and prvalues:

```cpp
const int number = 42;
Platform::String^ numberText = number.ToString();

Windows::Foundation::PropertyType kind = Windows::Foundation::PropertyType::Int32;
Platform::String^ kindText = kind.ToString();

Windows::Foundation::Point point{};
Platform::String^ pointText = point.ToString();

Platform::String^ FormatValue(Windows::Foundation::IPropertyValue^ value)
{
    return value->GetInt32().ToString(); // projected prvalue
}
```

Primitive member lookup uses the corresponding projected metadata value class. Top-level `const` is removed only while binding the projected member; the expression keeps its C++ value type. Metadata enums use `Platform::Enum`, WinRT value structs retain their projected members, and `Platform::Object::ToString()` is treated as the C++/CX override slot even though the raw WinMD method is not marked CLR-virtual.

Other repairs include:

- loading every evaluated `/FU` WinMD, including metadata produced by another C++/CX project in the same solution;
- projecting metadata enums, value classes, arrays, out parameters, pointer constness, and `Platform` core types according to metadata structure;
- restoring WinRT collection members and iterator/proxy behavior, standard range-for, and Microsoft C++/CX `for each`;
- preserving top-level `const` handle conversions, C++/CX boxing/unboxing, `Box<T>`/`IBox<T>` comparisons, handle/value equality, and target-specific conversions such as `TypeName` to `Platform::Type^`;
- supporting C++/CX delegate callback contexts and retention arguments, event registration tokens, wide literal `Platform::String^` concatenation, and enum-preserving `operator+`;
- resolving projected PPL async operations while retaining diagnostics for incompatible result interfaces, using the MSVC pointer-to-member fix shown in the async example.

#### Examples

**Language syntax and `Platform` types**

```cpp
[Windows::UI::Xaml::Data::Bindable]
public ref class ViewModel sealed
{
public:
    ViewModel() {}

    property Platform::Object^ Value
    {
        Platform::Object^ get() { return nullptr; }
    }
};

ViewModel^ viewModel = ref new ViewModel();
Platform::String^ text = L"Hello";
Platform::Object^ boxed = 42;
int value = safe_cast<int>(boxed);
```

JetBrains' existing managed PSI models ref classes, handles, properties, and managed allocation. The patch enables those models for `CppCx`, maps `ref new` to the managed allocation representation, and uses C++/CX `Platform` projections and conversions.

**Delegates, events, and weak references**

```cpp
auto handler = ref new Windows::Foundation::EventHandler<Platform::Object^>(
    [](Platform::Object^ sender, Platform::Object^ value) {});
Windows::Foundation::EventRegistrationToken token = source->Changed += handler;
source->Changed -= token;

Platform::WeakReference weakSource(source);
MyRuntimeClass^ resolved = weakSource.Resolve<MyRuntimeClass>();
```

C++/CX event subscription returns `Windows::Foundation::EventRegistrationToken`. Delegate construction also supports C++/CX `Platform::CallbackContext` and target retention arguments.

**WinRT metadata and collections**

```cpp
auto elements = ref new Platform::Collections::Map<int, Windows::UI::Xaml::FrameworkElement^>();

for each (auto pair in elements)
{
    Windows::UI::Xaml::FrameworkElement^ element = pair->Value;
    int key = pair->Key;
}
```

Platform, Windows SDK, and WinMD metadata of referenced projects are projected as C++/CX types. This includes collection interfaces, `Append`/`Size` members, iterators, proxies, range-based loops, `for each`, properties, methods, events, and out parameters.

**PPL and Windows Runtime async**

```cpp
concurrency::task<Platform::String^> ContinueAsync(Windows::Foundation::IAsyncOperation<Platform::String^>^ operation)
{
    return concurrency::create_task(operation).then([](Platform::String^ value) -> Platform::String^
    {
        return value;
    });
}
```

The patch retains `CppCx` preprocessing and enables the projected type and conversion paths used by MSVC's PPL headers.

The async templates exposed [RSCPP-15665](https://youtrack.jetbrains.com/issue/RSCPP-15665): MSVC accepts redundant parentheses around a qualified member in a pointer-to-member expression.

```cpp
class Type
{
public:
    void Method(int);
};

void Accept(void (Type::*member)(int));

void Bind()
{
    Accept(&(Type::Method));
}
```

The C++/CX branch of `ppltasks.h` uses the same form around a lambda call operator: `&(_Ty::operator())`. ReSharper applied `&` to the pointer-to-member type it had already inferred for the parenthesized expression, producing another pointer layer and losing the callback result during template deduction.

For MSVC dialects, direct and parenthesized qualified member addresses now resolve to the same pointer-to-member type. The existing template engine can then resolve the projected async base and check its result interface normally.

### IDE integration repairs: `JetBrains.ReSharper.Feature.Services.Cpp.dll`

This DLL implements editor-facing features on top of the language engine:

| Feature | C++/CX behavior |
|---------|-----------------|
| Completion | Includes native types that `platform.winmd` exposes as CLR-internal, uses `Platform::Enum` for projected enum members, and omits sealed WinRT methods from override completion. |
| Diagnostics | Accepts resolved projected members and boxing conversions; reports `*` on ref classes and interfaces, checked casts missing `^`, invalid ref-class destructor declarations, and public unsealed ref classes without a valid composable base. |
| Quick fixes | Replaces an invalid `*` with `^`, adds a missing `^` to `safe_cast` and `dynamic_cast` targets, and offers valid `safe_cast` or `dynamic_cast` conversions instead of `static_cast` for managed handles. |
| Code style | Places `const` after a handle (`T^ const&`) and keeps the required `virtual` keyword on public C++/CX destructors. |
| Navigation and search | Adds matching `vccorlib.h` definitions for declarations imported from `platform.winmd` and sends Go to Declaration on a delegate construction directly to the delegate class instead of a generated constructor chooser. |

These patches extend existing ReSharper C++ completion, inspection, quick fix, and navigation frameworks. C++/CX-only behavior is restricted to the `CppCx` dialect; C++/CLI keeps its existing paths. The remaining patches in this DLL are ILSpy reconstruction fixes needed to compile the decompiled project.

### Validation

Broad validation uses [Microsoft's pre-C# UWP Calculator codebase at commit `233339d`](https://github.com/microsoft/calculator/tree/233339d289ca1f422b3371e99a20311f93625ade), the last revision before "Hello C#."

## What the installer does

The installer:

1. Detects the Rider version and build from `product-info.json`.
1. Finds the best compatible source patch profile for that build.
1. Keeps original, signature-checked copies of Rider's two ReSharper C++ backend DLLs.
1. Clones the pinned ILSpy source when needed, applies the repository's decompiler compatibility patch, builds `ilspycmd`, and decompiles the DLLs into an isolated workspace under `Work`.
1. Applies the C++/CX source patches and builds both modified DLLs with .NET SDK 10 or newer.
1. Validates the resulting assembly identities, Rider version metadata, source fingerprints, and build manifest.
1. Installs the two modified DLLs and their matching R2R images as one transaction, retaining the signed originals as `.bak.dll` files and rolling back failures. If DLLs were copied in manually after a recorded install, the installer validates their Rider identity, preserves them with a hash manifest under `%LOCALAPPDATA%\ReSharperCppCx\Installations\<installation>\Recovery`, and then replaces them.
1. Records the installation outside Rider so a later update can replace the modded DLLs while retaining the same originals, and **Restore original DLLs** can uninstall the mod safely.

Generated workspaces, downloaded dependencies, and build products are not checked into the repository.

## FAQ

### Why not a plugin?

The required extension points are not exposed by Rider's supported plugin API. Stock ReSharper C++ rejects `CppCx` while creating its internal inclusion context, and the remaining compatibility work reaches into internal parser/PSI nodes, metadata scopes, type conversion, overload resolution, cache serialization, diagnostics, and C++ Feature Services.

A plugin can add actions and UI integrations, but it cannot use public APIs to change those core language semantics. A plugin based on runtime detours would still be a version-specific binary patch, only less reviewable and harder to validate. Source-level patches keep every change explicit, allow the two affected DLLs to be rebuilt together, and can be checked against multiple Rider builds.

### Why not use stock ILSpy?

ILSpy can export both DLLs as C# projects, but its stock project output does not reliably recompile these assemblies. The affected IL includes constructor initialization that ILSpy can turn into illegal instance field initializers, expression trees reconstructed through switch control flow and temporary stack slots, and `<Clone>$` helpers reconstructed as invalid or empty `with` initializers. Keeping those artifacts in the product patch profiles would mix decompiler repairs with the C++/CX changes.

The installer clones ILSpy tag `v11.0` at commit `cdeae656fee6e184ff76cdc549edc7f9031dba09` into the ignored `Tools/ILSpy` directory, applies [`Scripts/ILSpy.Compatibility.patch`](Scripts/ILSpy.Compatibility.patch), and builds `ilspycmd` locally for .NET 10. It verifies `ilspycmd` version `11.0.0.9375` and records both the ILSpy commit and compatibility-patch hash so a changed tool is rebuilt. Decompilation targets C# 13 with dead code and dead store cleanup enabled; the matching Rider XML documentation is placed beside each DLL so ILSpy imports its comments.

### Does this mod replace ReSharper C++'s C++/CLI implementation?

No. JetBrains' C++/CLI implementation remains the foundation. The mod retains the distinct `CppCx` dialect, opens shared managed C++ paths where the two languages agree, and adds separate C++/CX behavior where their preprocessing, type systems, metadata projections, or conversions differ. Preserving ordinary C++ and C++/CLI behavior is the first compatibility requirement.

### Why build the modified DLLs locally?

The repository distributes source patches, not JetBrains DLLs. A local build starts from the signed assemblies for the selected Rider build, applies the compatible patch profile, and validates both outputs before installation.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Legal notice

This is an independent, unofficial community project. It is not affiliated with, sponsored by, approved by, or endorsed by JetBrains s.r.o. JetBrains, Rider, ReSharper, and ReSharper C++ are trademarks or registered trademarks of JetBrains s.r.o.

This repository does not distribute JetBrains binaries. It distributes independently authored tooling and source-level patch instructions that operate on a user's own, lawfully obtained JetBrains installation or command-line tools. JetBrains' ordinary product and ReSharper Command Line Tools license terms restrict reverse engineering, decompilation, modification, derivative works, and redistribution. Some jurisdictions provide mandatory exceptions for interoperability, study, backup, or error correction, but whether an exception covers this project or a particular use depends on the facts and applicable law.

**The mod does not alter or disable product activation, JetBrains Account verification, subscription enforcement, trial limits, or any other licensing component. It provides no activation codes, license keys, key generators, or license servers, and the modified product still requires normal activation under the user's own JetBrains license.**

You are responsible for reviewing the terms that govern your copy of the JetBrains products and for obtaining any permission or legal advice you require before using this project. The project's MIT license applies only to material the project's contributors are legally entitled to license; it grants no rights in JetBrains software, decompiled JetBrains code, or JetBrains trademarks.

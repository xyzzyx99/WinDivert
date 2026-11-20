# WinDivert modern Visual Studio build (2026-11-20)

Target upstream: https://github.com/basil00/WinDivert (master), source reviewed on 2026-11-20.

## Scope

- `windivert-vs-modern.patch` (included at the ZIP root) retargets the 11
  MSBuild projects in the upstream source (DLL, 8 examples, test, kernel driver).
- `msvc-build-modern.ps1` selects an installed Visual Studio 2019, 2022,
  or 2026 toolchain via Microsoft's `vswhere.exe`.
- `.github/workflows/build-windivert-modern.yml` builds Windows 2022
  (VS 2022) and Windows 2025 (VS 2026), for x86 and x64.
- The default build compiles user-mode `WinDivert.dll`, the import library,
  example programs, and the test program.
- Kernel driver build is **optional**, via `-IncludeDriver`, and requires
  a compatible Windows Driver Kit. The generated driver is unsigned.

## Installation in your WinDivert checkout

1. Extract this ZIP **into the root** of the WinDivert source checkout so that
   the PowerShell script is beside `msvc-build.bat` and the workflow is in
   `.github/workflows/`.
2. Open PowerShell in that repository root.
3. Check and apply the modifications to existing project files:

   ```powershell
   git apply --check .\windivert-vs-modern.patch
   if ($LASTEXITCODE -ne 0) { throw 'Patch check failed' }
   git apply .\windivert-vs-modern.patch
   if ($LASTEXITCODE -ne 0) { throw 'Patch application failed' }
   ```

4. Build with a locally installed toolchain:

   ```powershell
   .\msvc-build-modern.ps1 -VSVersion 2022 -Architecture Both
   # Or on Visual Studio 2026:
   .\msvc-build-modern.ps1 -VSVersion 2026 -Architecture Both
   ```

   The default output tree is `install\MSVC\i386\` and
   `install\MSVC\amd64\`.

5. If a compatible WDK is installed, attempt an UNSIGNED kernel driver build:

   ```powershell
   .\msvc-build-modern.ps1 -VSVersion 2026 -Architecture x64 -IncludeDriver
   ```

6. To publish the modifications to your fork:

   ```powershell
   git add .github/workflows/build-windivert-modern.yml msvc-build-modern.ps1 `
       dll/windivert.vcxproj sys/windivert.vcxproj test/test.vcxproj examples
   git add README-modern-build.md windivert-vs-modern.patch
   git commit -m 'Support modern Visual Studio WinDivert builds'
   git push
   ```

For a cleaner repository history you may omit the ZIP's standalone patch
from the commit after applying it; it is provided for distribution and audit.

## Compiler toolset mapping

- VS 2019: `v142`
- VS 2022: `v143`
- VS 2026: `v145`
- Driver: `WindowsKernelModeDriver10.0` supplied by the matching WDK

For later toolchains, the script accepts a custom `-Toolset` value.
The project file fallback supports VS 2015–2026 with normal VS version values.

## CI workflow

1. Push changes to your WinDivert fork.
2. Open Actions > Build WinDivert (Visual Studio 2022 and 2026) > Run workflow.
3. Leave `build_driver` **off** for the portable user-mode build.
4. Download both workflow artifacts: `WinDivert-VS2022` and `WinDivert-VS2026`.

The optional `build_driver` input **requires a matching WDK on each runner**.
A Visual Studio WDK extension by itself does not guarantee the kit libraries
are installed; use an adequately provisioned runner if necessary.

## Compatibility/security cautions

- `sys/windivert.vcxproj` changes the driver target from `Windows7` to
  `Windows10` for modern WDK builds. This changes the supported OS target.
- The original `msvc-build.bat` is untouched. Use `msvc-build-modern.ps1`.
- Generated `.sys` files are UNSIGNED and are not drop-in substitutes for
  Microsoft's signed release drivers; do not disable Windows security features
  on production systems to make an unsigned driver load.
- A matching WDK/SDK and (where required) Spectre-mitigated build libraries
  are necessary for successful driver compilation.
- This bundle has been checked for patch structure and YAML validity, but
  is not yet compiled on a Windows runner. Project-source API incompatibilities
  with new WDKs may still require code changes.

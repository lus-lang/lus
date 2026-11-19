; Inno Setup script for the Lus Windows installer (lus-setup.exe).
;
; The windows-installer job in .github/workflows/release.yml unpacks the
; x86_64-windows release archive into the archive directory beside this
; file and compiles the installer with
;   ISCC.exe /DAppVer=2.0.0 /DNumVer=2.0.0 /O<outdir> lus.iss
; AppVer is the release version and NumVer its numeric x.y.z part, which
; the Windows version resource requires.
;
; The installer copies the archive as it is: bin\lus.exe with lus.dll,
; the embedding libraries in lib, lus.h in include, and the license
; texts. It adds {app}\bin to PATH.
;
; Per user by default: installs to {localappdata}\Programs\Lus and edits
; the user PATH, with no admin rights and no UAC prompt. Run with
; /ALLUSERS from an elevated prompt for a machine-wide install
; (Program Files and the system PATH). Standard silent flags apply:
; /VERYSILENT /SUPPRESSMSGBOXES.

#ifndef AppVer
  #define AppVer "0.0.0"
#endif
#ifndef NumVer
  #define NumVer "0.0.0"
#endif
#ifndef Archive
  #define Archive "archive"
#endif

[Setup]
AppId={{C7E2A2F4-9B71-4F28-A3D1-6E5D0B9C4A21}
AppName=Lus
AppVersion={#AppVer}
AppPublisher=The Lus Project
AppPublisherURL=https://lus.dev
AppSupportURL=https://lus.dev/manual
LicenseFile={#Archive}\LICENSE.md
; {autopf} resolves per install mode: {localappdata}\Programs in
; per-user mode, and C:\Program Files under /ALLUSERS.
DefaultDirName={autopf}\Lus
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
ChangesEnvironment=yes
OutputBaseFilename=lus-setup
VersionInfoVersion={#NumVer}.0
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\bin\lus.exe

[Files]
Source: "{#Archive}\*"; DestDir: "{app}"; Excludes: "*.pdb"; \
  Flags: ignoreversion recursesubdirs createallsubdirs

; Releases before 2.0 placed lus.exe and lusc.exe directly in {app}.
[InstallDelete]
Type: files; Name: "{app}\lus.exe"
Type: files; Name: "{app}\lusc.exe"

; Append {app}\bin to PATH in the hive matching the install mode. The
; NeedsAddPath gate keeps reinstalls and upgrades from duplicating the
; entry. The uninstaller removes it in CurUninstallStepChanged.
[Registry]
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; \
  ValueData: "{olddata};{app}\bin"; \
  Check: (not IsAdminInstallMode) and NeedsAddPath(ExpandConstant('{app}\bin'))
Root: HKLM; Subkey: "SYSTEM\CurrentControlSet\Control\Session Manager\Environment"; \
  ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}\bin"; \
  Check: IsAdminInstallMode and NeedsAddPath(ExpandConstant('{app}\bin'))

[Code]
function PathRegRoot: Integer;
begin
  if IsAdminInstallMode then Result := HKEY_LOCAL_MACHINE
  else Result := HKEY_CURRENT_USER;
end;

function PathRegKey: String;
begin
  if IsAdminInstallMode then
    Result := 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
  else
    Result := 'Environment';
end;

function NeedsAddPath(Dir: String): Boolean;
var
  OrigPath: String;
begin
  if not RegQueryStringValue(PathRegRoot, PathRegKey, 'Path', OrigPath) then
  begin
    Result := True;
    exit;
  end;
  { Semicolon-bounded, case-insensitive containment check. }
  Result := Pos(';' + Lowercase(Dir) + ';', ';' + Lowercase(OrigPath) + ';') = 0;
end;

{ Removes Dir from PATH in the hive matching the install mode. }
procedure RemovePath(Dir: String);
var
  OrigPath: String;
  P: Integer;
begin
  if not RegQueryStringValue(PathRegRoot, PathRegKey, 'Path', OrigPath) then
    exit;
  { Find the entry on the semicolon-padded copy. For match position P,
    P = 1 means Dir leads OrigPath, so strip Dir and the semicolon after
    it. Otherwise OrigPath[P-1] is the semicolon before Dir, so strip
    that semicolon and Dir. Lowercased copies share lengths with the
    originals, so P indexes OrigPath directly. }
  P := Pos(';' + Lowercase(Dir) + ';', ';' + Lowercase(OrigPath) + ';');
  if P = 0 then
    exit;
  if P = 1 then
    Delete(OrigPath, 1, Length(Dir) + 1)
  else
    Delete(OrigPath, P - 1, Length(Dir) + 1);
  RegWriteExpandStringValue(PathRegRoot, PathRegKey, 'Path', OrigPath);
end;

// Releases before 2.0 put the application directory itself on PATH. An
// upgrade replaces that entry with its bin subdirectory.
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    RemovePath(ExpandConstant('{app}'));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    RemovePath(ExpandConstant('{app}\bin'));
end;

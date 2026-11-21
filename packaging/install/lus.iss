; Inno Setup script for the Lus Windows installer (lus-setup.exe).
;
; The windows-installer job in .github/workflows/release.yml unpacks the
; x86_64-windows release archive into the archive directory beside this
; file and compiles the installer with
;   ISCC.exe /DAppVer=2.0.0 /DNumVer=2.0.0 /O<outdir> lus.iss
; AppVer is the release version and NumVer its numeric x.y.z part, which
; the Windows version resource requires.
;
; The installer lays the release out as the Lus home that `lus version`
; manages (spec/tools/version.md). It copies the archive as it is into
; {app}\versions\<version>: bin\lus.exe with lus.dll, the embedding
; libraries in lib, lus.h in include, and the license texts. It copies
; lus.exe to {app}\bin, writes the version to {app}\default and the
; channel to the version's channel file, and adds {app}\bin to PATH.
;
; Per user by default: installs to {localappdata}\lus, the default Lus
; home on Windows, and edits the user PATH, with no admin rights and no
; UAC prompt. Run with /ALLUSERS from an elevated prompt for a
; machine-wide install in Program Files with the system PATH. `lus
; version` manages the per-user home, so a machine-wide install is
; outside its reach unless LUS_HOME names it. Standard silent flags
; apply: /VERYSILENT /SUPPRESSMSGBOXES.

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
; {localappdata}\lus in per-user mode, C:\Program Files\Lus under
; /ALLUSERS.
DefaultDirName={code:DefaultHome}
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
Source: "{#Archive}\*"; DestDir: "{app}\versions\{#AppVer}"; Excludes: "*.pdb"; \
  Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#Archive}\bin\lus.exe"; DestDir: "{app}\bin"; Flags: ignoreversion

; Releases before 2.0 placed lus.exe and lusc.exe directly in {app}.
[InstallDelete]
Type: files; Name: "{app}\lus.exe"
Type: files; Name: "{app}\lusc.exe"

; The uninstaller removes the versions that `lus version` installed and
; the module cache, which the installer did not copy.
[UninstallDelete]
Type: filesandordirs; Name: "{app}\versions"
Type: filesandordirs; Name: "{app}\cache"
Type: filesandordirs; Name: "{app}\index"
Type: files; Name: "{app}\default"
Type: files; Name: "{app}\lock"

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
function DefaultHome(Param: String): String;
begin
  if IsAdminInstallMode then Result := ExpandConstant('{autopf}\Lus')
  else Result := ExpandConstant('{localappdata}\lus');
end;

{ Records the installed version as the default and its channel, as
  `lus version install` does. }
procedure WriteHomeFiles;
var
  Channel: String;
begin
  if Pos('-unstable', '{#AppVer}') > 0 then Channel := 'unstable'
  else Channel := 'stable';
  SaveStringToFile(ExpandConstant('{app}\versions\{#AppVer}\channel'), Channel + #10, False);
  SaveStringToFile(ExpandConstant('{app}\default'), '{#AppVer}' + #10, False);
end;

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
  begin
    RemovePath(ExpandConstant('{app}'));
    WriteHomeFiles;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    RemovePath(ExpandConstant('{app}\bin'));
end;

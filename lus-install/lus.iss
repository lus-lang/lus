; Inno Setup script for the Lus Windows installer (lus-setup.exe).
;
; Compiled in CI (see the installer job in .github/workflows/build.yml):
;   ISCC.exe /DAppVer=1.6.0 /O<outdir> lus.iss
; with the release lus.exe placed next to this file beforehand.
;
; Per-user by default: installs to {localappdata}\Programs\Lus and
; edits the user PATH — no admin rights, no UAC prompt. Run with
; /ALLUSERS from an elevated prompt for a machine-wide install
; (Program Files + system PATH). Standard silent flags apply:
; /VERYSILENT /SUPPRESSMSGBOXES.

#ifndef AppVer
  #define AppVer "0.0.0"
#endif

[Setup]
AppId={{C7E2A2F4-9B71-4F28-A3D1-6E5D0B9C4A21}
AppName=Lus
AppVersion={#AppVer}
AppPublisher=The Lus Project
AppPublisherURL=https://lus.dev
AppSupportURL=https://lus.dev/manual
LicenseFile=..\LICENSE.md
; {autopf} resolves per install mode: {localappdata}\Programs in
; per-user mode, C:\Program Files under /ALLUSERS.
DefaultDirName={autopf}\Lus
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
ChangesEnvironment=yes
OutputBaseFilename=lus-setup
VersionInfoVersion={#AppVer}.0
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\lus.exe

[Files]
Source: "lus.exe"; DestDir: "{app}"; Flags: ignoreversion

; Append {app} to PATH in the hive matching the install mode. The
; NeedsAddPath gate keeps reinstalls/upgrades from duplicating the
; entry; the uninstaller removes it in CurUninstallStepChanged.
[Registry]
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; \
  ValueData: "{olddata};{app}"; \
  Check: (not IsAdminInstallMode) and NeedsAddPath(ExpandConstant('{app}'))
Root: HKLM; Subkey: "SYSTEM\CurrentControlSet\Control\Session Manager\Environment"; \
  ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}"; \
  Check: IsAdminInstallMode and NeedsAddPath(ExpandConstant('{app}'))

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

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  OrigPath, Dir: String;
  P: Integer;
begin
  if CurUninstallStep <> usPostUninstall then
    exit;
  Dir := ExpandConstant('{app}');
  if not RegQueryStringValue(PathRegRoot, PathRegKey, 'Path', OrigPath) then
    exit;
  { Find the entry on the ';'-padded copy: for match position P,
    P = 1 means Dir leads OrigPath (strip Dir plus its trailing ';'),
    otherwise OrigPath[P-1] is the ';' preceding Dir (strip ';'+Dir).
    Lowercased copies share lengths with the originals, so P indexes
    OrigPath directly. }
  P := Pos(';' + Lowercase(Dir) + ';', ';' + Lowercase(OrigPath) + ';');
  if P = 0 then
    exit;
  if P = 1 then
    Delete(OrigPath, 1, Length(Dir) + 1)
  else
    Delete(OrigPath, P - 1, Length(Dir) + 1);
  RegWriteExpandStringValue(PathRegRoot, PathRegKey, 'Path', OrigPath);
end;

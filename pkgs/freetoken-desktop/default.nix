{
  lib,
  stdenv,
  fetchurl,
  addDriverRunpath,
  autoPatchelfHook,
  copyDesktopItems,
  dpkg,
  makeDesktopItem,
  makeWrapper,
  wrapGAppsHook3,

  cairo,
  dbus,
  gdk-pixbuf,
  glib,
  gtk3,
  libayatana-appindicator,
  libsoup_3,
  webkitgtk_4_1,

  # The engine the GUI drives. Wired in as FREETOKEN_FT_BIN so the app talks to
  # the Nix `ft` instead of running its bundled installer, which would try to
  # build a uv venv under ~/.freetoken. Set to null for a GUI-only build.
  freetoken,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "freetoken-desktop";
  version = "0.2.0-beta.22";

  # Upstream publishes only binaries; the desktop app is not open source.
  src = fetchurl {
    url = "https://github.com/FlashML-org/FreeToken-Web/releases/download/v${finalAttrs.version}/freetoken-desktop-amd64.deb";
    hash = "sha256-jaIz643xWwd2cJvPxWRgKKLg16mMEgUfXvRsNfU5Snk=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    copyDesktopItems
    dpkg
    makeWrapper
    wrapGAppsHook3
  ];

  buildInputs = [
    cairo
    dbus
    gdk-pixbuf
    glib
    gtk3
    libsoup_3
    webkitgtk_4_1
  ];

  # Loaded with dlopen, so autoPatchelf cannot see them in DT_NEEDED:
  # libayatana-appindicator for the tray icon, libnvidia-ml.so.1 (from the
  # driver, at runtime) for the GPU readout.
  runtimeDependencies = [ libayatana-appindicator ];

  unpackCmd = "dpkg-deb -x $curSrc source";
  sourceRoot = "source";

  dontBuild = true;
  dontConfigure = true;

  desktopItems = [
    (makeDesktopItem {
      name = "freetoken-desktop";
      desktopName = "FreeToken Desktop";
      comment = "Local LLM runtime control panel";
      exec = "freetoken-desktop";
      icon = "freetoken-desktop";
      startupWMClass = "freetoken-desktop";
      terminal = false;
      # Upstream's own .desktop ships `Categories=` empty, which leaves the app
      # unfiled (or hidden) in most launchers.
      categories = [
        "Utility"
        "Development"
      ];
      keywords = [
        "AI"
        "FreeToken"
        "LLM"
        "inference"
      ];
    })
  ];

  installPhase = ''
    runHook preInstall

    install -Dm755 usr/bin/freetoken-desktop $out/bin/freetoken-desktop

    # Tauri resolves its resource dir relative to the executable, so keep the
    # bundle layout ($out/bin + $out/lib/<product name>) exactly as shipped.
    mkdir -p "$out/lib"
    cp -r "usr/lib/FreeToken Desktop" "$out/lib/FreeToken Desktop"

    mkdir -p $out/share
    cp -r usr/share/icons $out/share/icons

    runHook postInstall
  '';

  # wrapGAppsHook3 does the final wrapping; add ours to the same wrapper rather
  # than nesting a second one.
  # No WebKit renderer override here on purpose: the app has its own
  # `linux_webkit` probe and picks a transport itself (and rejects the usual
  # WEBKIT_DISABLE_DMABUF_RENDERER as unsafe on WebKitGTK 2.52, which is what
  # nixpkgs ships). If a window comes up blank, run it once with
  # WEBKIT_DMABUF_RENDERER_FORCE_SHM=1, which is what upstream asks for.
  preFixup = ''
    gappsWrapperArgs+=(
      --suffix LD_LIBRARY_PATH : ${addDriverRunpath.driverLink}/lib
      ${lib.optionalString (freetoken != null) ''
        --set-default FREETOKEN_FT_BIN ${lib.getExe freetoken}
      ''}
    )
  '';

  passthru = { inherit freetoken; };

  meta = {
    description = "Desktop control panel for the FreeToken inference engine";
    longDescription = ''
      FreeToken Desktop is FlashML's GUI for FreeToken: a model library, a
      chat console, engine start/stop and live cache/VRAM tuning. It drives a
      local `ft` engine, which this package points at the Nix one through
      FREETOKEN_FT_BIN.

      Upstream ships the app only as a prebuilt binary, so this is a repackaged
      .deb rather than a build from source, and its in-app updater cannot
      replace anything inside the Nix store — upgrade the package instead.
    '';
    homepage = "https://www.flashml.ai/";
    changelog = "https://www.flashml.ai/changelog/";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "freetoken-desktop";
    platforms = [ "x86_64-linux" ];
  };
})

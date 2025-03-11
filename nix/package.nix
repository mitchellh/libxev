{ stdenv
, lib
, zig
, pkg-config
, scdoc
}:

stdenv.mkDerivation rec {
  pname = "libxev";
  version = "0.1.0";

  src = ./..;

  nativeBuildInputs = [ zig scdoc pkg-config ];

  buildInputs = [];

  dontConfigure = true;

  preBuild = ''
    # Necessary for zig cache to work
    export HOME=$TMPDIR
  '';

  installPhase = ''
    runHook preInstall
    zig build -Doptimize=ReleaseFast -Demit-man-pages --prefix $out install
    runHook postInstall
  '';

  outputs = [ "out" "dev" "man" ];

  meta = with lib; {
    description = "A high performance, cross-platform event loop.";
    homepage = "https://github.com/mitchellh/libxev";
    license = licenses.mit;
    platforms = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
  };
}

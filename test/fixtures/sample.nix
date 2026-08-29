{ pkgs, ... }:
{
  services.syncthing = {
    enable = true;
    guiAddress = "127.0.0.1:8385";
  };

  services.openssh = {
    enable = true;
    ports = [ 2222 ];
  };
}

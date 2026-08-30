# Todo / Findings

Aus zwei kompletten Testbench-Durchläufen (echter Build, Debian 13).

## Offen

- [ ] Voller Fresh-Rebuild-Test von `run_install_deps()`: bleibt der
      mysql-apt-config-whiptail-Dialog bei einem kompletten
      `./acore.sh install-deps` wirklich weg? Bisher nur der Mechanismus
      standalone getestet (debconf/frontend-Flip + Restore), nicht durch einen
      echten Lauf. Auth allein reicht (install-deps ist bei Auth/World gleich).

## Erledigt



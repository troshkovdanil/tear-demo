# Nix + RAUC Incremental Artifact Update PoC

This proof of concept demonstrates how **RAUC** and **Nix** can cooperate for
application-level OTA updates without putting the complete application payload
inside the RAUC bundle.

RAUC is responsible for the **signed release intent**: it authenticates a small
artifact that says which Nix store path should become the desired application
release.

Nix is responsible for the **application closure**: it resolves the desired
store path against a signed binary cache, reuses paths already present on the
device, downloads only missing paths, and verifies them.

The PoC intentionally uses a separate simulated device Nix store so that the
incremental behavior is easy to observe without modifying the host's active
Nix store.

## Goal

The experiment models this update architecture:

```text
                 UPDATE SERVER
                       |
             signed release intent
                       |
                       v
                     RAUC
                       |
                artifact installed
                       |
                       v
               application updater
                       |
              desired Nix path
                       |
                       v
                Nix resolver
                       |
          +------------+-------------+
          |                          |
          v                          v
   already on device          missing store paths
        reuse                       fetch
          |                          |
          +------------+-------------+
                       |
                       v
                complete closure
                       |
                    verify
                       |
                       v
              stage / activate
```

The current PoC implements the path through **fetch and verification**. A
production implementation can extend it with explicit staging, health
validation, atomic profile/generation switching, and rollback.

## Why combine RAUC and Nix?

RAUC and Nix solve different parts of the update problem.

```text
 RAUC signing key                     Nix cache signing key
       |                                      |
       v                                      v
 signed update metadata             signed Nix store paths
       |                                      |
       +---------------+        +-------------+
                       v        v
                         DEVICE
                           |
              +------------+------------+
              |                         |
          RAUC verifies             Nix verifies
          release intent           downloaded paths
              |                         |
              +------------+------------+
                           |
                           v
                    application release
```

RAUC answers:

> Is this an authorized OTA release instruction?

Nix answers:

> Can I construct the requested application closure from authenticated,
> content-addressed store paths?

This means the RAUC bundle can stay very small. It does not need to contain
glibc, Bash, jq, the application, and every other dependency. It can carry only
the desired Nix store root.

## Incremental update demonstrated by this PoC

V1 and V2 intentionally share most of their closure. V2 adds `jq`, which also
adds its dependencies.

Conceptually:

```text
V1 simulated device store

├── bash ────────────────┐
├── glibc                |
├── libidn2              +── REUSED
├── libunistring         |
├── libgcc ──────────────┘
└── hello-rauc-v1

              update to V2
                    |
                    v
          signed binary cache
                    |
          only missing paths
                    |
                    v
├── oniguruma ─────────── NEW
├── jq ────────────────── NEW
├── jq-bin ────────────── NEW
└── hello-rauc-v2 ─────── NEW
```

In the demonstrated run, the V1 closure contains six paths. Updating to V2
requires only four additional paths. Nix queries the full desired closure but
copies only those four missing paths.

## Components

```text
setup.sh
  ├─ creates flake.nix
  ├─ builds V1 and V2
  ├─ generates Nix cache signing key
  ├─ signs the application closures
  ├─ creates a signed binary cache containing V1 and V2
  ├─ generates RAUC development signing certificate/key
  ├─ creates simulated DEVICE store containing only V1
  ├─ creates RAUC artifact repository configuration
  └─ creates nix-artifact-updater + post-install handler

produce.sh
  ├─ reads the V2 Nix store root
  ├─ creates tiny release metadata containing that root
  ├─ creates a signed RAUC verity bundle
  ├─ verifies the RAUC signature
  └─ verifies that V2 is available from the Nix binary cache

consume.sh
  ├─ records DEVICE state before installation
  ├─ installs the signed RAUC metadata bundle
  │    └─ RAUC post-install handler
  │         └─ nix-artifact-updater
  │              └─ nix copy signed cache → DEVICE
  └─ proves that only missing paths were added

clean.sh
  └─ returns the directory to scripts-only state

install-prerequisites.sh
  ├─ installs host/build dependencies on Ubuntu
  ├─ installs official multi-user Nix
  ├─ enables nix-command + flakes
  └─ builds and installs RAUC 1.15.2 under /usr/local
```

## End-to-end data flow

```text
                    OTA / UPDATE SERVER
                           |
                           | signed RAUC bundle
                           v
                    +-------------+
                    |    RAUC     |
                    | trust + OTA |
                    +------+------+
                           |
                    release metadata
                           |
                           v
                    desired Nix path
                           |
                           v
                    +-------------+
                    |     Nix     |
                    |   updater   |
                    +------+------+
                           |
                 query signed binary cache
                           |
                           v
                  resolve desired closure
                           |
              +------------+------------+
              |                         |
         path exists                path absent
         on DEVICE                  on DEVICE
              |                         |
            reuse                      fetch
              |                         |
              +------------+------------+
                           |
                           v
                  simulated /nix/store
                           |
                      verify closure
```

There are therefore two independent trust domains:

1. **RAUC bundle signature** authenticates the release decision.
2. **Nix store signatures** authenticate the store paths fetched to satisfy
   that decision.

The release descriptor does not replace Nix verification, and Nix verification
does not replace the signed OTA decision.

## Host support

The PoC was initially run from NixOS and is also designed to run on Ubuntu.

The Ubuntu path deliberately uses:

- official multi-user Nix;
- the normal `/nix/store`;
- Ubuntu host tools;
- RAUC 1.15.2 built from source and installed as `/usr/local/bin/rauc`.

Ubuntu 24.04 provides an older RAUC package (1.11.3 in the tested environment).
That version rejects the artifact repository configuration used by this PoC:

```ini
[artifacts.nix-releases]
path=...
type=files
```

For that reason `install-prerequisites.sh` installs RAUC 1.15.2 under
`/usr/local` while leaving the distribution RAUC untouched.

After installation it is possible to have both:

```text
/usr/bin/rauc        -> Ubuntu packaged RAUC 1.11.3
/usr/local/bin/rauc  -> PoC RAUC 1.15.2
```

The PoC should use `/usr/local/bin/rauc`.

## Ubuntu prerequisites

Run once:

```bash
chmod +x install-prerequisites.sh
./install-prerequisites.sh
```

If Nix was installed during that run, open a new terminal before continuing.
Alternatively load the Nix environment manually:

```bash
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
```

Verify:

```bash
nix --version
nix-store --version
/usr/local/bin/rauc --version
```

Expected RAUC version:

```text
rauc 1.15.2
```

`nix develop` is not required for the Ubuntu workflow because the prerequisite
installer provides the required host tools directly.

## Step 1 — Build the releases and initialize the simulated device

Run as the normal user:

```bash
./setup.sh
```

`setup.sh` creates a flake with two application releases.

V1 is a small `hello-rauc` shell application. V2 adds `jq` as a runtime
dependency so that the Nix closure changes in an observable way.

A representative closure difference is:

```text
--- common ---
libunistring
libidn2
glibc
libgcc
bash

--- new in V2 ---
hello-rauc-v2
oniguruma
jq
jq-bin
```

The exact Nix store hashes and package versions may change when the pinned
`nixpkgs` input changes.

The script then:

1. generates a Nix binary-cache signing key;
2. signs both application closures;
3. copies V1 and V2 into the simulated server cache;
4. generates a RAUC development certificate;
5. creates a separate simulated device store;
6. copies **only V1** into that device store;
7. confirms that V2 is absent.

The resulting topology is:

```text
host /nix/store
      |
      | builds
      v
  V1 + V2
      |
      | sign + nix copy
      v
work/server/nix-cache
      |
      | initial provisioning
      | V1 only
      v
work/device-store
```

The separate `work/device-store` is important. It lets the demo prove which
paths would be present on a target before and after an update without treating
the host `/nix/store` as the target device.

## Step 2 — Produce the signed release intent

Run:

```bash
./produce.sh
```

The producer reads:

```text
work/app-v2.path
```

and creates a release descriptor whose useful payload is simply:

```text
/nix/store/<hash>-hello-rauc
```

It is packaged as the RAUC artifact:

```ini
[image.nix-releases/hello-rauc]
filename=hello-rauc.release
```

The result is:

```text
work/server/bundles/hello-rauc-v2.raucb
```

The bundle is signed with the RAUC development key and uses the RAUC verity
bundle format.

The producer also verifies that the desired V2 root actually exists in the
server-side Nix binary cache. This prevents publishing a valid RAUC release
instruction that points to a closure the Nix server cannot provide.

The important separation is:

```text
RAUC bundle
    |
    | 55-byte release descriptor in the demonstrated run
    v
desired /nix/store/...-hello-rauc

Nix binary cache
    |
    +── application
    +── libraries
    +── runtime tools
    └── complete dependency closure
```

The physical RAUC bundle is larger than the descriptor because it contains
bundle/filesystem, verity, manifest, and signature data. The important point is
that the **application closure itself is not duplicated inside the RAUC
bundle**.

## Step 3 — Start the RAUC service

Use a second terminal and run:

```bash
sudo /usr/local/bin/rauc \
    -c "$PWD/work/config/system.conf" \
    service --override-boot-slot=_external_
```

`sudo` is intentional. A real RAUC system service performs privileged update
operations, and the PoC keeps that execution model.

The absolute `/usr/local/bin/rauc` path is also intentional: `sudo` may use a
different `PATH`, and Ubuntu's `/usr/bin/rauc` may still be the older 1.11.3
package.

A successful startup looks approximately like:

```text
Using central status file .../work/rauc-data/central.raucs
Using system config file .../work/config/system.conf
Booted from external source
```

Leave this terminal running.

## Step 4 — Consume the update

From the first terminal run:

```bash
sudo ./consume.sh
```

The logical path is:

```text
consume.sh
    |
    v
RAUC install
    |
    +── verify RAUC bundle signature
    |
    +── insert hello-rauc artifact into nix-releases repository
    |
    v
post-install handler
    |
    v
nix-artifact-updater
    |
    +── read desired /nix/store path
    |
    +── query signed binary cache
    |
    +── resolve complete closure
    |
    +── reuse paths already in DEVICE
    |
    +── copy missing signed paths
    |
    └── verify resulting closure
```

A successful RAUC service log includes operations such as:

```text
Verified inline signature by 'O = nix-rauc-lab, CN = nix-rauc-lab development'
Inserted artifact into repo 'nix-releases': 'hello-rauc' ...
Starting post install handler: .../rauc-post-install
[nix-artifact-updater] desired root: /nix/store/...-hello-rauc
[nix-artifact-updater] fetching missing closure paths...
copying 4 paths...
[nix-artifact-updater] verifying desired closure...
[nix-artifact-updater] update complete
Installation ... succeeded
```

## What proves that the update is incremental?

For the demonstrated V1 → V2 transition, V1 already contains:

```text
bash
glibc
libidn2
libunistring
libgcc
hello-rauc-v1
```

Nix queries dependencies required by V2, discovers that the common dependencies
already exist in the simulated device store, and copies only:

```text
oniguruma
jq
jq-bin
hello-rauc-v2
```

Thus:

```text
             desired V2 closure
                     |
             Nix dependency graph
                     |
          +----------+----------+
          |                     |
          v                     v
   DEVICE already has      DEVICE lacks
        5 shared               4 new
       dependencies             paths
          |                     |
        reuse                  fetch
          +----------+----------+
                     |
                     v
              complete V2
```

The exact number of shared and new paths is specific to the package closure
used in a given run; the invariant being tested is that Nix transfers only
missing store paths.

## What RAUC does and does not transport

This distinction is central to the experiment.

Traditional payload-oriented OTA can look like:

```text
RAUC bundle
    |
    +── application binary
    +── libraries
    +── dependencies
    └── other payload files
```

This PoC instead uses:

```text
RAUC bundle
    |
    └── signed release descriptor
              |
              v
       desired Nix store root
              |
              v
        Nix binary cache
              |
       closure resolution
              |
       incremental transfer
```

RAUC remains the trusted OTA control plane, while Nix acts as the
content-addressed application delivery mechanism.

## Toward activation and rollback

The current PoC deliberately stops short of implementing a production
activation policy.

The intended next layer is:

```text
              binary cache
                   |
                   | desired path = V3
                   v
              Nix resolver
                   |
        +----------+----------+
        |                     |
        v                     v
 already installed          missing
      reuse                  fetch
        +----------+----------+
                   |
                   v
              STAGE V3
                   |
             validate / health
                   |
                   v
              atomic switch
                   |
                success?
               /        \
             yes         no
              |           |
              v           v
          keep V3     switch back V2
```

Nix profiles/generations are a natural mechanism to investigate for the NixOS
side of this activation layer.

The key design rule is that fetching a valid new closure and making it active
are separate operations. A production updater should be able to construct and
validate the new release while the previous release remains active.

## Relationship to full-system RAUC A/B updates

This experiment does **not** propose replacing RAUC A/B system updates.

A device may use both:

```text
                    DEVICE OTA
                        |
             +----------+----------+
             |                     |
             v                     v
      system / OS update     application update
             |                     |
             v                     v
        RAUC A/B slots       RAUC release intent
                                   |
                                   v
                             Nix binary cache
                                   |
                                   v
                          incremental closure
```

RAUC A/B remains appropriate for boot-critical system images. The mechanism in
this PoC is aimed at smaller, independently updateable application/workload
artifacts.

## Possible Yocto analogue

Nix gives this design content-addressed paths, dependency closure resolution,
incremental transfer, verification, generations, and garbage-collection
machinery.

For a Yocto-based target, possible application-update backends include:

### OSTree

OSTree already provides content-addressed storage, incremental transfer,
atomic deployment, and rollback. It is therefore a strong candidate for the
closest analogue to the Nix side of this design.

### RPM/DNF or IPK feeds plus versioned application trees

For example:

```text
/opt/releases/
    v41/
    v42/

/opt/current -> /opt/releases/v42
```

Package-feed machinery could provide missing packages while an application
updater constructs and validates a new versioned tree before switching
`/opt/current`.

The difficulty is that dependency resolution, deduplication, atomic
generations, garbage collection, and rollback can gradually become a custom
deployment system.

### RAUC artifact repository plus versioned trees

RAUC artifact repositories can also maintain application artifacts and
versioned content. This may be useful when the application dependency model is
simple enough that a separate Nix/OSTree-like resolver is unnecessary.

A broader architecture could therefore be:

```text
                 UPDATE SERVER
                       |
             signed release intent
                       |
                       v
                     RAUC
                       |
                application updater
                       |
              +--------+--------+
              |                 |
            NixOS              Yocto
              |                 |
        binary cache      deployment backend
              |          (e.g. OSTree or
       missing store       package feed)
          objects               |
              +--------+--------+
                       |
                  STAGE release
                       |
                    validate
                       |
                       v
                 atomic switch
```

The backend can differ by operating system while RAUC remains the signed
release-control layer.

## Security model

This PoC uses development keys generated locally by `setup.sh`.

They are suitable only for demonstrating the architecture.

A production system would need, at minimum:

- protected RAUC release-signing keys;
- controlled Nix cache-signing keys;
- secure provisioning of trust anchors;
- key rotation and revocation strategy;
- release/version policy and rollback protection;
- authenticated transport where appropriate;
- staging and application health validation;
- atomic activation;
- rollback after failed validation or startup;
- lifecycle management and garbage collection of old store paths.

The two signatures should remain conceptually independent: authorization of a
release and authentication of the objects composing that release are different
security decisions.

## Generated directory structure

After `setup.sh` and `produce.sh`, the important generated files are
approximately:

```text
work/
├── app-v1.path
├── app-v2.path
├── bundle-input/
│   ├── hello-rauc.release
│   ├── manifest.raucm
│   └── padding.bin
├── config/
│   └── system.conf
├── device-store/
│   └── nix/
│       └── store/
├── keys/
│   ├── nix-cache-secret.key
│   ├── nix-cache-public.key
│   ├── rauc.key.pem
│   └── rauc.cert.pem
├── nix-artifact-updater
├── rauc-post-install
├── rauc-data/
├── rauc-releases/
└── server/
    ├── bundles/
    │   └── hello-rauc-v2.raucb
    └── nix-cache/
```

`work/` is disposable PoC state.

## Cleanup

Stop the RAUC service and run:

```bash
sudo ./clean.sh
```

The cleanup script returns the directory to its source/scripts-only state so
the experiment can be repeated from scratch.

## Quick run — Ubuntu

Terminal 1:

```bash
# One-time host preparation:
./install-prerequisites.sh

# Open a new terminal if Nix was installed for the first time.

./setup.sh
./produce.sh
```

Terminal 2:

```bash
sudo /usr/local/bin/rauc \
    -c "$PWD/work/config/system.conf" \
    service --override-boot-slot=_external_
```

Back in Terminal 1:

```bash
sudo ./consume.sh
```

Finally:

```bash
sudo ./clean.sh
```

## Summary

The PoC demonstrates a division of responsibility that can be useful for
application-level OTA:

```text
RAUC
  └── authenticates "which release should this device install?"

Nix
  └── determines "which authenticated objects are needed to construct it?"
```

Instead of shipping a complete application closure in every OTA bundle, the
update infrastructure can send a small signed release intent and let the
content-addressed package/deployment backend transfer only what the target is
missing.

The demonstrated V1 → V2 update therefore validates the core idea:

**signed release intent with RAUC + signed, incremental application delivery
with Nix.**

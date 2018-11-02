# OpenXT manifest

Simple manifest to play around with OpenXT using repo instead of the proposed
build systems. This aims to provide a more direct and simple way to build the
project without relying on a specific container technology or imposing changes
in one's work-flow.

## Usual workflow

mkdir master
pushd master
repo init -u https://github.com/eric-ch/openxt-manifest
repo sync
repo start --all master
./scripts/quirks-patches.sh
./scripts/openxt.sh certs
[...]
./scripts/openxt.sh build
./scripts/openxt.sh deploy iso

## Manifests

### default.xml

Development manifest.

* openembedded/bitbake: 1.34;
* openembedded/openembedded-core: pyro;
* openembedded/meta-openembedded: pyro;
* meta-intel: pyro;
* meta-java: pyro;
* meta-selinux: master;
* meta-virtualization: pyro;


### stable-8.xml

Stabilisation manifest for 8.x releases.

* openembedded/bitbake: 1.34;
* openembedded/openembedded-core: 819aa151bd634122a46ffdd822064313c67f5ba5;
* openembedded/meta-openembedded: 9eaebc6e783f1394bb5444326cd05a976b3122e9;
* meta-intel: 9b37952d6af36358b6397cedf3dd53ec8962b6bf;
* meta-java: 0c27b120aa508e4bb41394b8dd3645949a611128;
* meta-selinux: b1dac7e2b26f869c991c6492aa7fa18eaa4b47f6;
* meta-virtualization: 45ad257a1e4a6707c376d2f7eb26c3c8bdf03607;


### stable-7.xml

Stabilisation manifest for 7.x releases.

* openembedded/bitbake: 68d061d2517f1a79dc6b14a373ed2dcb78a901ce;
* openembedded/openembedded-core: 6af6e285e8bed16b02dee27c8466e9f4f9f21e30;
* openembedded/meta-openembedded: 2ea8d7f54a061e902657c4f8ea1f7f7c25c6c4e1;
* meta-intel: 4e8b0ef1e521dc45dcc310b6b7528bfe1eed1274;
* meta-java: a73939323984fca1e919d3408d3301ccdbceac9c;
* meta-selinux: 4c75d9cbcf1d75043c7c5ab315aa383d9b227510;
* meta-virtualization: 042425c1d98bdd7e44a62789bd03b375045266f5;


### stable-6.xml

Stabilisation manifest for 6.x releases.

* openembedded/bitbake: b993d96203541cd2919d688559ab802078a7a506;
* openembedded/openembedded-core: 1f4bfa33073584c25396d74f3929f263f3df188b;
* openembedded/meta-openembedded: 8ab04afbffb4bc5184cfe0655049de6f44269990;
* meta-java: a73939323984fca1e919d3408d3301ccdbceac9c;
* meta-selinux: 4c75d9cbcf1d75043c7c5ab315aa383d9b227510;



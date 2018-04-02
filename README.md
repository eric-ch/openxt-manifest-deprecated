# OpenXT manifest

Simple manifest to play around with OpenXT using repo instead of the proposed
build systems. This aims to provide a more direct and simple way to build the
project without relying on a specific container technology or imposing changes
in one's work-flow.

## Manifests

### default.xml

Development manifest.

* OpenXT: master branch;
* Bitbake: tag 1.34;
* OpenEmbedded-core & meta-Openembedded: pyro branch;
* meta-intel, meta-java, meta-virtualization: pyro branch;
* meta-selinux: master branch;

### stable-8

Stabilisation manifest for 8.x releases.

* OpenXT: stable-8 branch;
* Bitbake: tag 1.34;
* openembedded-core: revision 5e4b4874c4;
* meta-openembedded: revision dfbdd28d2;
* meta-intel: revision 42072ef;
* meta-java: revision 0c27b12;
* meta-virtualization: revision 45ad257;
* meta-selinux: revision d855c62;

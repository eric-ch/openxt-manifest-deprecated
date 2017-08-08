Simple manifest to play around with OpenXT using repo instead of the proposed
build systems.

Known issues:
1- Problem with libtirpc
| src/rpcb_svc_com.o: In function `handle_reply':
| /home/build/openxt/master-0/tmp-glibc/work/core2-32-oe-linux/rpcbind/0.2.3-r0/rpcbind-0.2.3/src/rpcb_svc_com.c:1298: undefined reference to `svc_auth_none'
| collect2: error: ld returned 1 exit status
Addressed by https://github.com/eric-ch/xenclient-oe/commit/0c1ac3f682f0b7c67628c2c93e45eba9e164cb19

2- OpenXT should add "multiarch" to DISTRO_FEATURES.
Addressed by https://github.com/eric-ch/xenclient-oe/commit/66625887c982e1133d455970227e7e6b18f5adf8

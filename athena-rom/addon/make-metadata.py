#!/usr/bin/env python3
"""Метаданные аддона, не зависящие от версии прошивки.

Пишет META-INF/com/android/metadata (текст) и metadata.pb (protobuf) так,
чтобы аддон ставился через LineageOS Updater поверх ЛЮБОЙ нашей сборки:

* post-timestamp = 2100-01-01. Updater (InstallUtils.getBlockedReason) зовёт
  DOWNGRADE всё, у чего timestamp < ro.build.date.utc аппарата; recovery для
  пакетов ota-type=BLOCK метку времени не смотрит вовсе
  (install.cpp: CheckPackageMetadata "Skip package metadata check").
* sdk_level = SDK текущего Android. Больше нельзя: osSdkLevel > sdkLevel даёт
  VERSION_UNSUPPORTED; меньше нельзя: DOWNGRADE. Менять вместе с мажорной
  версией Android.
* spl_downgrade = true и SPL из текущей сборки. Recovery (spl_check.cpp)
  отказывает, если SPL пакета старше SPL аппарата, но бит spl_downgrade это
  разрешает. Аддон не трогает build.prop, так что SPL аппарата не меняет.

Использование: make-metadata.py <каталог со staging zip> [sdk] [spl]
"""
import os, sys
sys.path.insert(0, '/data/LOS232/build/make/tools/releasetools')
import ota_metadata_pb2 as pb

root = sys.argv[1]
sdk = sys.argv[2] if len(sys.argv) > 2 else '36'
spl = sys.argv[3] if len(sys.argv) > 3 else ''
if not spl:
    try:
        for line in open('/data/los23out2/target/product/athena/system/build.prop'):
            if line.startswith('ro.build.version.security_patch='):
                spl = line.strip().split('=', 1)[1]
    except OSError:
        pass
spl = spl or '2026-01-01'
FUTURE = 4102444800  # 2100-01-01 UTC

m = pb.OtaMetadata()
m.type = pb.OtaMetadata.BLOCK
m.precondition.device.append('athena')
m.postcondition.device.append('athena')
m.postcondition.build.append('athena/awg-addon')
m.postcondition.build_incremental = str(FUTURE)
m.postcondition.timestamp = FUTURE
m.postcondition.sdk_level = sdk
m.postcondition.security_patch_level = spl
m.spl_downgrade = True

d = os.path.join(root, 'META-INF/com/android'); os.makedirs(d, exist_ok=True)
open(os.path.join(d, 'metadata.pb'), 'wb').write(m.SerializeToString())
open(os.path.join(d, 'metadata'), 'w').write(
    'ota-required-cache=0\n'
    'ota-type=BLOCK\n'
    'post-build=athena/awg-addon\n'
    f'post-build-incremental={FUTURE}\n'
    f'post-sdk-level={sdk}\n'
    f'post-security-patch-level={spl}\n'
    f'post-timestamp={FUTURE}\n'
    'pre-device=athena\n'
    'spl-downgrade=yes\n')
print(f'metadata: sdk={sdk} spl={spl} timestamp={FUTURE} (2100-01-01)')

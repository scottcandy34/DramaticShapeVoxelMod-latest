# Deprecated drop path

**Player and in-game ROM location is the mod-root folder:**

    baseroms/baserom.z64

(not this directory).

This folder remains only so older offline pipeline invocations and
checkouts keep working. Prefer:

    model_extract/pipeline/build.py --rom=../../baseroms/baserom.z64

or place the ROM in the mod-root `baseroms/` folder (the pipeline searches
there first when updated).

Expected MD5 (US 1.0): `ed1378bc12115f71209a77844965ba50`.

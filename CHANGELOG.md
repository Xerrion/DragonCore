# Changelog

## 1.0.0 (2026-05-14)


### 🚀 Features

* **addonchannel:** add per-(addon, prefix) AddonChannel with in-house serializer ([bd3e3b6](https://github.com/Xerrion/DragonCore/commit/bd3e3b6e4c709c18e829fda8b30facfbb0a32978))
* **core:** add Listener + Bus taint-isolation primitives ([f3d7abf](https://github.com/Xerrion/DragonCore/commit/f3d7abf1aaa54628817c4f0b4464d4f70be44787))
* **lifecycle:** add Lifecycle orchestration root with resource bag ([3b5a80a](https://github.com/Xerrion/DragonCore/commit/3b5a80a9be7f5a51fb7951788c2093a2ada92a8e))
* **locale:** add per-addon Locale registry ([5a936a1](https://github.com/Xerrion/DragonCore/commit/5a936a1a6c4ecb146bb57ef8d2e2822e72accdbf))
* **settings:** add Settings registry with modern/legacy renderers ([500ac0e](https://github.com/Xerrion/DragonCore/commit/500ac0ea241357ab1f0796a37a5690e17cc664d8))
* **settings:** collapse to single Modern renderer with settingsAPI capability gate ([#1](https://github.com/Xerrion/DragonCore/issues/1)) ([49f4323](https://github.com/Xerrion/DragonCore/commit/49f4323c2652460e6e58c44f20b327582e59a3ed))
* **store:** add SavedVariables-backed Store with 8 scope accessors ([79756ea](https://github.com/Xerrion/DragonCore/commit/79756ea1f94c0b22915e2838565e082477fede3b))


### 🚜 Refactor

* **dispatcher:** extract snapshot-on-iterate dispatcher primitive ([e2dce95](https://github.com/Xerrion/DragonCore/commit/e2dce95874d673625f1f9e9bcd99394d03acf17a))
* rename Bus to EventBus and update methods to Subscribe/Publish ([0baf718](https://github.com/Xerrion/DragonCore/commit/0baf718ca815f9dc132323d053db38276f0d65e4))


### ⚙️ Miscellaneous Tasks

* add Capabilities detection module and shared test bootstrap ([f74f17f](https://github.com/Xerrion/DragonCore/commit/f74f17fdf0453c7387f483a8eac3f0553a0629af))
* add Schedule module and shared wow_mock virtual-clock harness ([36e0147](https://github.com/Xerrion/DragonCore/commit/36e0147d096543652188732d24017071f9cc1c81))
* add SecureCall module for taint-safe callback dispatch ([45c45ed](https://github.com/Xerrion/DragonCore/commit/45c45ed28c805128a6f6d6bbf3476c889c950f5b))
* add v0 TOC and pkgmeta packaging manifests ([f50b0e6](https://github.com/Xerrion/DragonCore/commit/f50b0e605c0ff2f80e225ab9072bf0e3e55bf1f8))
* **github:** backfill family-standard repo hygiene ([#3](https://github.com/Xerrion/DragonCore/issues/3)) ([ad8dd40](https://github.com/Xerrion/DragonCore/commit/ad8dd407e4b0d00bd26573dfbf5b3b51b860fbae))
* initial repo scaffold ([b5da0ff](https://github.com/Xerrion/DragonCore/commit/b5da0ffbbad09556f8c8f0fe57349cd1e4c2c66d))
* scaffold Subscription async primitive and busted infrastructure ([db1af4b](https://github.com/Xerrion/DragonCore/commit/db1af4b0c424a3e4778387883d0967e99d0198a0))

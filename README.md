# iAPS: Your Experimental Artificial Pancreas System for iOS

iAPS is an advanced artificial pancreas system for iOS, built upon the foundation of Ivan Valkou's original `freeaps.git` Swift repository and powered by the **OpenAPS Reference (Master 0.7.1)** algorithms. After thousands of commits and the addition of many unique features, the app has been rebranded as iAPS under the new organization, Artificial Pancreas. We also leverage numerous frameworks published by the **Loop community** to bring you this robust system.


-----

## Aurora Dexcom G6 Direct Controls — Experimental Snapshot

This repository is a public snapshot of the Aurora Dexcom G6 development work. It is intended for code review, testing, and collaboration and is **not an official upstream iAPS release**.

The G6-specific work in this snapshot includes:

* **Direct Dexcom G6 sensor start** from iAPS using a valid 4-digit sensor code.
* **Direct sensor stop** from iAPS.
* **Direct calibration** from iAPS.
* **Transmitter change/setup** for 6-character G6 transmitter IDs.
* **Passive-mode coexistence** with the Dexcom app. Normal operation can remain passive while start, stop, and calibration use a temporary one-shot active command cycle.
* **Anubis support** retained.
* **Warmup countdown on the iAPS home screen**, derived from the actual sensor-session start time and restored after an app restart.
  * Standard G6 warmup: **120 minutes**
  * Anubis warmup: **50 minutes**
* Automatic return from the warmup countdown to the normal sensor-age display when warmup completes.

The G6 implementation uses the public snapshot of **CGMBLEKit-G6-Public** referenced as a Git submodule.

Clone this snapshot with all required submodules:

```bash
git clone --recurse-submodules https://github.com/holger2de/iAPS-Aurora-G6-Public.git
cd iAPS-Aurora-G6-Public
```

> **Experimental:** This code controls CGM session commands and is still being tested with real sensor changes. Review and test carefully before relying on it.


-----

## Get Started with this Aurora G6 Snapshot

To build and review the Aurora Dexcom G6 development snapshot, clone **this repository** with all submodules:

### Clone and open in Xcode

```bash
git clone --recurse-submodules https://github.com/holger2de/iAPS-Aurora-G6-Public.git
cd iAPS-Aurora-G6-Public
xed .
```

### Update submodules in an existing clone

```bash
git submodule update --init --recursive
```

### Update this public snapshot

```bash
git pull
git submodule update --init --recursive
```

### Upstream iAPS

This repository is based on iAPS and is **not the official upstream project**.

Official upstream repository:

```text
https://github.com/Artificial-Pancreas/iAPS
```

Use the upstream repository for the current official iAPS development branch and general project history.
  
### Build Without Xcode (Directly in GitHub)

For instructions on how to build iAPS directly within GitHub, refer to these resources:

  * **iAPS-Specific Instructions:** [https://github.com/Artificial-Pancreas/iAPS/blob/main/fastlane/testflight.md](https://github.com/Artificial-Pancreas/iAPS/blob/main/fastlane/testflight.md)
  * **General GitHub Actions Overview:** [https://loopkit.github.io/loopdocs/gh-actions/gh-overview/](https://loopkit.github.io/loopdocs/gh-actions/gh-overview/)

-----

## Important Considerations

Please understand that iAPS is:

  * **Highly experimental and rapidly evolving.**
  * **Not CE or FDA approved for therapy.**

The Near Field Communication (NFC) capability requires a paid Apple developer membership, however if using Dexcom sensors with iAPS you don't need the NFC capability enabled in Xcode capability settings.
Distributing and building TestFlight apps also requires a paid membership.

-----

## Compatible Devices

### Insulin Pumps

  * **Omnipod EROS**
  * **Omnipod DASH**
  * **Omnipod 5**
  * **Medtrum TouchCare Nano**
  * **Dana:**
      * Dana-I
      * DanaRS (firmware 3 only)
  * **Medtronic:**
      * 515 or 715 (any firmware)
      * 522 or 722 (any firmware)
      * 523 or 723 (firmware 2.4 or lower)
      * Worldwide Veo 554 or 754 (firmware 2.6A or lower)
      * Canadian/Australian Veo 554 or 754 (firmware 2.7A or lower)

### CGM Sensors

  * **Dexcom:**
      * G5
      * G6
      * ONE
      * ONE +
      * G7
  * **Libre:**
      * 1
      * 2 (European)
      * 2 Plus (European)
  * **Eversense**
      * E3 (90 & 180 days)
      * 365
  * **Medtronic Enlite**
  * **Nightscout** (as CGM)

### iPhone and iPod Compatibility

The iAPS app runs on your **iPhone** or **iPod**. An **iPhone 8 or newer** is required, running a **minimum of iOS 17**.

-----

## Documentation and Community

Connect with the iAPS community and find helpful resources here:

  * **Discord iAPS Server:** [https://discord.com/invite/ptkk2Y264Z](https://discord.com/invite/ptkk2Y264Z)
  * **Facebook Group:** [https://www.facebook.com/groups/403549385863967](https://www.facebook.com/groups/403549385863967)
  * **iAPS Statistics:** [https://open-iaps.org](https://open-iaps.org)
  * **iAPS Documentation (under development):** [https://iaps.readthedocs.io/en/latest/](https://iaps.readthedocs.io/en/latest/)
  * **OpenAPS Documentation:** [https://openaps.readthedocs.io/en/latest/](https://openaps.readthedocs.io/en/latest/)
  * **Crowdin Project for iAPS Translation:** [https://crowdin.com/project/iaps](https://crowdin.com/project/iaps)
    [](https://crowdin.com/project/iaps) [![Crowdin](https://badges.crowdin.net/iaps/localized.svg)](https://crowdin.com/project/iaps)
  * **Middleware code for iAPS:** [https://github.com/Jon-b-m/middleware](https://github.com/Jon-b-m/middleware)
  * **Omnipod DASH Pump and Settings:** [https://loopkit.github.io/loopdocs/loop-3/omnipod/](https://loopkit.github.io/loopdocs/loop-3/omnipod/)

-----

## Contribute to iAPS

We welcome your contributions to improve iAPS\!

  * **Code contributions** via Pull Requests are highly encouraged.
  * **Translators** can join our Crowdin project by clicking the link above.
  * For **questions or other contributions**, please email jon.m@live.se.

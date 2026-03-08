# GitLab CI Alternative

```yaml
stages: [lint, build, test, artifact, sign, verify, provenance]

lint:
  stage: lint
  script:
    - swift package dump-package > /dev/null

build_macos:
  stage: build
  tags: [macos]
  script:
    - swift build --product sprout
    - swift build --product sprout-updater
    - swift build --product sprout-macos

build_linux:
  stage: build
  image: swift:6.0-jammy
  script:
    - swift build --product sprout
    - swift build --product sprout-updater

test_macos:
  stage: test
  tags: [macos]
  script:
    - swift test

test_linux:
  stage: test
  image: swift:6.0-jammy
  script:
    - swift test

artifact_macos:
  stage: artifact
  tags: [macos]
  script:
    - bash Scripts/build_release_bundle.sh dist macos-arm64

artifact_linux:
  stage: artifact
  image: swift:6.0-jammy
  script:
    - bash Scripts/build_release_bundle.sh dist linux-x86_64

sign:
  stage: sign
  script:
    - bash Scripts/sign_release_bundle.sh dist
  rules:
    - if: '$CI_PIPELINE_SOURCE != "merge_request_event"'

provenance:
  stage: provenance
  script:
    - echo "Generate provenance/attestation with your chosen GitLab signing service or CI integration."

verify:
  stage: verify
  script:
    - bash Scripts/verify_release_bundle.sh dist
```

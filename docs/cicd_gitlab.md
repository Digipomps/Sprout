# GitLab CI Alternative

```yaml
stages: [lint, build, test, artifact, sign, verify, provenance]

lint:
  stage: lint
  script:
    - swift package diagnose-api-breaking-changes || true

build:
  stage: build
  script:
    - swift build --product sprout
    - swift build --product sprout-updater
    - swift build --product sprout-macos

test:
  stage: test
  script:
    - swift test

artifact:
  stage: artifact
  script:
    - zsh Scripts/build_release_bundle.sh dist

sign:
  stage: sign
  script:
    - zsh Scripts/sign_release_bundle.sh dist
  rules:
    - if: '$CI_PIPELINE_SOURCE != "merge_request_event"'

provenance:
  stage: provenance
  script:
    - echo "Generate provenance/attestation with your chosen GitLab signing service or CI integration."

verify:
  stage: verify
  script:
    - zsh Scripts/verify_release_bundle.sh dist
```

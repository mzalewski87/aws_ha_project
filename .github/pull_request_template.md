<!-- Conventional Commit title, e.g. feat(firewall): ... / fix(routing): ... / docs: ... -->

## What & why


## Phase / scope
<!-- 1a / 2a / 1b / 2b / 3 / GP / R2 / optional-eks / docs -->

## Checks
- [ ] `terraform fmt -check -recursive` clean
- [ ] `terraform validate` clean on affected workspace(s): root / phase2-panorama-config / optional/eks-deploy
- [ ] No secrets committed (tfvars, keys, `*.auto.tfvars`, rendered init-cfg)
- [ ] Docs updated if behaviour/vars changed (README / docs/DEPLOYMENT.md / module README)

## Live-verification notes
<!-- Anything that can only be confirmed on a live AWS/Panorama deploy -->

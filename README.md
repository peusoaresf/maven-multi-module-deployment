# Maven Multi-Module Deployment

This repo explores maven multi-module projects and attempts to set in place a smooth release process around it.

## Dependencies

- [Make](https://www.gnu.org/software/make/)
- [Java SDK (v25)](https://sdkman.io/)

## Getting Start

This repo setups up an imaginary application consisting of an `api` and a `scheduler` modules, that both depend on a `core` module.

To start the api, run:

```
make spring-run module=api
```

Aand then, to issue test requests, simply:

```
curl http://localhost:8080/greet/world
```

The actual app code or functionalities are non-important, since this repo is focused on the build system / release process around such a modularized service.

## More Context

As I came to learn, multi-module maven projects are quite a simple concept (and at a basic level, also simple to implement) but properly automating and orchestrating versioning / releases is a bit of a different beast.

At the most basic level we simply define a parent project (pom.xml) which in turn lists all child modules, all of which have their own internal standard maven/java structure and pom.xml. Should a module depend on another module, we simply decribe the dependency as a normal `<dependency />` block inside the module's pom.xml. 

The parent project may be home to shared configurations / plugins, but as far as my experiments showed, attempting to manage child module versions in a centralized place (thus avoiding children referencing specific versions of each other) is a bit foolish. Centralizing this kind of information in the parent makes it really hard to fully reconcile parent and children versioning: a parent change might signal a requirement to redeploy ALL child, so in this instance, when we only update the parent to declare a new version of a child, what's exactly the next course of action ? Redeploy everyone even though only one child changed ? (can you feel the weird recursive loop situation? it sort of defeats the purpose of a multi-module-separate-deployment project)

Because of that, this project centralizes shared configuration in the parent project, but lets children explicitly declare their dependencies to other children.

To make it concrete, we have the following structure:

```
- Root

|-> core

|-> api
  |-> depends on core

|-> scheduler
  |-> depends on core
```

We should be able to:
- Version and deploy `api` and `scheduler` independently when they are the only things to change in a changeset;
- Whenever `core` changes, cascade the version bump (and consequently deploy) to `api` and `scheduler`;
- Whenever `root` changes, cascade the version bump (and consequently deploy) to all children (making sure to resolve interdependency between children, ie, when a child gets bumped because of root, someone depending on this child should get a bump on the `<dependency>` block for the child).
- Make sure levels are respected, eg, imagine `api` has already been bumped due to a feature (minor level) being implemented on it; later a patch level change comes to `core`. The system must identify that a bigger bump level has already been applied to `api` and issue a noop.

The release process of this repo leverages the premise that we are always working on the bleeding edge of versions for it. That is, whatever change comes in during development time, must, at commit time, resolve which bump a module should receive (staying, ofc, within a SNAPSHOT reach). This way, as changes come through, we can bump the system accordingly, signalling to the outside world what they should expect as next version, and by the time a release gets triggered, resolution becomes a simple matter of triggering deploy for the updated modules (stripping SNAPSHOT).

This is achieved by hooking a script to each commit that comes into the `main` branch, running some procedures to resolve who should receive bumps according to the `commit message` and `files changed`, and, persisting outcomes in a `.release-plan` file of the format:

```
module-name=bump-level
.
.
// where bump-level is one of: patch | minor | major | none
```

The makefile recipe `bump-module-version` accepts a `module` name, a bump `level`, and whether changes should be flushed to the `.release-plan` file or not (`plan` param). The recipe will leverage what it can from maven, plus many cli tools to bump the provided module version, while also bumping their dependencies to match the new module version. 

With that in place, the next make recipe that leverages the previous one and makes the magic happen is: `on-commit`. This recipe receives the commit message and the file paths changed and checks whether the parent or any module requires bumping (analysing the dependency graph to match every dependency to the correct version bumps, making sure higher levels are not overwritten by lesser levels).

### Examples

1. An imported module cascades its changes to dependants, but won't overwrite a higher level previous bump:

```
make on-commit msg="feat: only api changed and bumped" files="api/src/main/java/App.java"

make on-commit msg="deps: core update cascades to scheduler but not api" files="core/src/main/java/com/example/core/GreetingService.java"
```

2. An update to the parent project should update all modules' imported parent version, consequently patching them and resolving any module inter-dependency to match:

```
make on-commit msg="feat: shared config changed" files="Dockerfile"
```

### Next steps

At this point, we could most likely safely hook the current `on-commit` recipe to a github action reacting to pushes to main and get a pretty consistent versioning resolution going on, a few high-level missing steps to make this a full-blown deployment pipeline would be:

- Commit back to main all snapshot bumps incurred by `on-commit` ;
- Create a new hook `on-release` that would:
  1. Strip SNAPSHOT from all pom.xml files
  2. Read changed modules in `.release-plan`
  3. Build & Deploy them to: 
      a. artifactory
      b. harbor
      c. argocd_apps
  4. Rollback snapshot stripping
  5. Generate a github release at the latest hash including commits, contributors and the deployed modules (+ their levels)
  6. Set all modules = none in the `.release-plan` file 


## Dependencies & Blockers

I might have to install the following tools in the pipeline VM in order to use `xmllint`:

```
apt-get install -y libxml2-utils
```

## Quirks

1. `SHELL := /bin/bash` is needed to support herestring (`<<<`)

2. `make msg-to-level msg="feat!: lala"` won't work but `make msg-to-level msg='feat!: lala'` will

3. `@printf '%b\n' "$(files)"` is required to preserve \n as proper newline (instead of being interpreted as literal characters)

4. `MAKEFLAGS += --no-print-directory` prevents recursive call logs such as:

```
make[1]: Entering directory '/Users/ferraped/Projects/personal/maven-multi-module-deployment'
make[1]: Leaving directory '/Users/ferraped/Projects/personal/maven-multi-module-deployment'
```

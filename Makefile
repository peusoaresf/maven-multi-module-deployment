SHELL := /bin/bash
.ONESHELL:

.PHONY: clean
clean:
	./mvnw clean

.PHONY: test
test: clean
	./mvnw -pl $(module) -am test

.PHONY: spring-run
spring-run: clean
	./mvnw -pl $(module) -am spring-boot:run

deploy:
	@if [ -z "$(modules)" ]; then \
		echo "Missing required params, usage:\n\nmake deploy modules=<comma,separated,modules>\n"; \
		exit 1; \
	fi;

	./mvnw deploy -pl $(modules) -am

# set-module-version:
# 	@if [ -z "$(module)" ] || [ -z "$(version)" ]; then \
# 		echo "Missing required params, usage:\n\nmake set-module-version module=<module-name> version=<new-version eg.: 1.0.0>\n"; \
# 		exit 1; \
# 	fi;

# 	./mvnw versions:set -DnewVersion=$(version) -pl $(module) -DgenerateBackupPoms=false
# 	sed -i.bak "/<artifactId>$(module)<\/artifactId>/{n;s|<version>[^<]*</version>|<version>$(version)</version>|;}" pom.xml && rm pom.xml.bak

set-parent-version-cascade:
	@if [ -z "$(version)" ]; then \
		echo "Missing required params, usage:\n\nmake set-parent-version-cascade version=<new-parent-version eg.: 1.0.0>\n"; \
		exit 1; \
	fi;

	./mvnw versions:set -DnewVersion=$(version) -DgenerateBackupPoms=false

get-pom-version:
	@if [ -z "$(pom)" ]; then \
		echo "Missing required params, usage:\n\nmake get-pom-version pom=<path/to/pom.xml>\n"; \
		exit 1; \
	fi;

	@xmllint --xpath '/*[local-name()="project"]/*[local-name()="version"]/text()' $(pom)

# TODO: set the version in the end?
calculate-bumped-version:
	@if [ -z "$(current)" ] || [ -z "$(level)" ]; then
		echo "Missing required params, usage:\n\nmake calculate-bumped-version current=<current-version eg.: 1.0.0-SNAPSHOT> level=<one-of [major,minor,path]>\n";
		exit 1;
	fi;

	current=$(current);
	level=$(level);

	IFS='.' read -r major minor patch <<< "$${current%-SNAPSHOT}";

	case $$level in
		patch) patch=$$((patch + 1)) ;;
		minor) minor=$$((minor + 1)); patch=0 ;;
		major) major=$$((major + 1)); minor=0; patch=0 ;;
		*) echo "unknown level: $$level" >&2; exit 1 ;;
	esac;

	echo "$${major}.$${minor}.$${patch}"

list-modules:
	@grep -oE '<module>[^<]+</module>' pom.xml | sed 's/<[^>]*>//g'

# strip-snapshot:
# 	@if [ -z "$(module)" ]; then \
# 		echo "Missing required params, usage:\n\nmake strip-snapshot module=<module-name>\n"; \
# 		exit 1; \
# 	fi; \
# 	current=$$(make get-pom-version pom=$(module)/pom.xml); \
# 	make set-module-version module=$(module) version=$${current%-SNAPSHOT}

# add-snapshot:
# 	@if [ -z "$(module)" ]; then \
# 		echo "Missing required params, usage:\n\nmake add-snapshot module=<module-name>\n"; \
# 		exit 1; \
# 	fi; \
# 	current=$$(make get-pom-version pom=$(module)/pom.xml); \
# 	make set-module-version module=$(module) version=$${current%-SNAPSHOT}-SNAPSHOT

remove-snapshot:
	./mvnw versions:set -DremoveSnapshot -pl $(module) -DgenerateBackupPoms=false

next-snapshot:
	./mvnw versions:set -DnextSnapshot -pl $(module) -DgenerateBackupPoms=false

clean-deploy:
	rm -rf .local-artifactory/snapshots .local-artifactory/releases


# FROM THIS POINT ONWARDS this is all working really well!

list-module-poms:
	@find . -name "pom.xml" \
		-not -path "./pom.xml" \
		-not -path "./$(ignore)/pom.xml" \
		-not -path "./.m2/*" \
		-not -path "./target/*" \
		-not -path "./.local-artifactory/*"

does-pom-reference-module:
	@grep -q "<artifactId>$(module)<\/artifactId>" "$(pom)" && echo "true" || echo "false"

set-dependency-version:
	@sed -i.bak "/<artifactId>$(module)<\/artifactId>/{n;s|<version>[^<]*</version>|<version>$(version)</version>|;}" $(pom) && rm $(pom).bak

get-module-name-from-pom-path:
	@dirname "$(pom)" | sed 's|^\./||'

is-already-bumped:
	@grep -q "^$(module)=" .release-plan 2>/dev/null && echo "true" || echo "false"

set-module-version:
	@if [ -z "$(module)" ] || [ -z "$(version)" ]; then
		printf "\nMissing required params, usage:\n\n";
		printf "make set-module-version module=<module-name> version=<new-version eg.: 1.0.0>\n\n";
		exit 0;
	fi;

	./mvnw versions:set -DnewVersion=$(version) -pl $(module) -DgenerateBackupPoms=false;

	# TODO: any way to reuse this somehow?
	# TODO: could I just call this function 'bump-module' and pass the level instead ?
	if [ "$(plan)" = "true" ]; then
		[ -f .release-plan ] && sed -i.bak "/^$(module)=/d" .release-plan && rm -f .release-plan.bak
		echo "$(module)=$(level)" >> .release-plan
	fi

	for pom in $$($(MAKE) -s list-module-poms ignore=$(module)); do
		[ "$$($(MAKE) -s does-pom-reference-module pom=$$pom module=$(module))" = "true" ] || continue;

		$(MAKE) -s set-dependency-version pom=$$pom module=$(module) version=$(version);

		dependent_module=$$($(MAKE) -s get-module-name-from-pom-path pom=$$pom);

		[ "$$($(MAKE) -s is-already-bumped module=$$dependent_module)" = "false" ] || continue;

		current=$$($(MAKE) -s get-pom-version pom=$$pom);
		bumped=$$($(MAKE) -s calculate-bumped-version current=$$current level=patch);

		$(MAKE) set-module-version module=$$dependent_module version=$${bumped}-SNAPSHOT plan=$(plan) level=patch;
	done

msg-to-level:
	@if echo "$(msg)" | grep -qE '^[^:]+!:'; then
		echo major
	elif echo "$(msg)" | grep -qE '^feat(\(.+\))?:'; then
		echo minor
	elif echo "$(msg)" | grep -qE '^(fix|refactor|deps)(\(.+\))?:'; then
		echo patch
	else
		echo none
	fi

level-to-num:
	@case $(level) in
		patch) echo 1 ;;
		minor) echo 2 ;;
		major) echo 3 ;;
		*) echo 0 ;;
	esac

files-touch-module:
	@echo "$(files)" | tr ' ' '\n' | grep -q "^$(module)/" && echo "true" || echo "false"

is-level-upgrade:
	@current_level=$$(grep "^$(module)=" .release-plan 2>/dev/null | cut -d= -f2)
	current_level_num=$$($(MAKE) -s level-to-num level=$${current_level:-none})
	new_level_num=$$($(MAKE) -s level-to-num level=$(level))
	[ "$$new_level_num" -gt "$$current_level_num" ] && echo "true" || echo "false"

on-commit:
	@level=$$($(MAKE) -s msg-to-level msg="$(msg)")
	[ "$$level" != "none" ] || exit 0

	for module in $$($(MAKE) -s list-modules); do
		[ "$$($(MAKE) -s files-touch-module module=$$module files="$(files)")" = "true" ] || continue
		[ "$$($(MAKE) -s is-level-upgrade module=$$module level=$$level)" = "true" ] || continue

		current=$$($(MAKE) -s get-pom-version pom=$$module/pom.xml)
		bumped=$$($(MAKE) -s calculate-bumped-version current=$$current level=$$level)

		$(MAKE) set-module-version module=$$module version=$${bumped}-SNAPSHOT plan=true level=$$level
	done

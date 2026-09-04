SHELL := /bin/bash
MAKEFLAGS += --no-print-directory
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

clean-deploy:
	rm -rf .local-artifactory/snapshots .local-artifactory/releases

# TODO: I can clean snapshots in one shot with a string replace tbh
clean-snapshot:
	echo "Not implemented"

# ######################################################################
# FROM THIS POINT ONWARDS this is all working really well for on-commit!

list-modules:
	@printf '.\n'
	@grep -oE '<module>[^<]+</module>' pom.xml | sed 's/<[^>]*>//g'

list-module-poms:
	@find . -name "pom.xml" \
		-not -path "./pom.xml" \
		-not -path "./$(ignore)/pom.xml" \
		-not -path "./.m2/*" \
		-not -path "./target/*" \
		-not -path "./.local-artifactory/*"

get-pom-version:
	@if [ -z "$(pom)" ]; then \
		echo "Missing required params, usage:\n\nmake get-pom-version pom=<path/to/pom.xml>\n"; \
		exit 1; \
	fi;

	@xmllint --xpath '/*[local-name()="project"]/*[local-name()="version"]/text()' $(pom)

does-pom-reference-module:
	@if [ "$(module)" = "." ]; then
		echo "true"
		exit 0
	fi

	grep -q "<artifactId>$(module)<\/artifactId>" "$(pom)" && echo "true" || echo "false"

set-dependency-version:
	printf " \- Setting <$$module:$$version> in <$$pom>\n"

	@sed -i.bak "/<artifactId>$(module)<\/artifactId>/{n;s|<version>[^<]*</version>|<version>$(version)</version>|;}" $(pom) && rm $(pom).bak

get-module-name-from-pom-path:
	@dirname "$(pom)" | sed 's|^\./||'

is-already-bumped:
	@level=$$(grep "^$(module)=" .release-plan | cut -d= -f2)

	if [ -n "$$level" ] && [ "$$level" != "none" ]; then
		echo "true"
		exit 0
	fi

	echo "false"

calculate-bump-version:
	@if [ -z "$(current)" ] || [ -z "$(level)" ]; then
		printf "\nMissing required params, usage:\n\n";
		printf "make calculate-bump-version current=<current-version eg.: 1.0.0-SNAPSHOT> level=<major|minor|path]>\n\n";
		exit 0;
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

update-release-plan:
	if [ -f .release-plan ]; then
		sed -i.bak "/^$(module)=/d" .release-plan
		rm -f .release-plan.bak
	fi

	echo "$(module)=$(level)" >> .release-plan

bump-module-version:
	@if [ -z "$(module)" ] || [ -z "$(level)" ]; then
		printf "\nMissing required params, usage:\n\n";
		printf "make bump-module-version module=<module-name> level=<major|minor|patch>\n\n";
		exit 0;
	fi;

	current_version=$$($(MAKE) -s get-pom-version pom=$$module/pom.xml);
	bumped_version=$$($(MAKE) -s calculate-bump-version current=$$current_version level=$$level)-SNAPSHOT;

	printf "Bumping <$$module> from <$$current_version> to <$$bumped_version>\n"

	./mvnw -q versions:set -DnewVersion=$$bumped_version -pl $(module) -DgenerateBackupPoms=false -DupdateMatchingVersions=false;

	$(MAKE) -s update-release-plan module=$(module) level=$(level)

	for other_pom in $$($(MAKE) -s list-module-poms ignore=$(module)); do
		printf "Analyzing potential references to <$$module> in <$$other_pom>\n"

		if [ "$$($(MAKE) -s does-pom-reference-module pom=$$other_pom module=$(module))" = "false" ]; then
			printf " \- Skipping dependant bumps since <$$other_pom> does not reference $$module\n"
			continue;
		fi

		$(MAKE) -s set-dependency-version pom=$$other_pom module=$(module) version=$$bumped_version;

		dependant_module=$$($(MAKE) -s get-module-name-from-pom-path pom=$$other_pom);

		if [ "$$($(MAKE) -s is-already-bumped module=$$dependant_module)" = "true" ]; then
			printf " \- Skipping auto-cascading patch to <$$dependant_module> since it already received a higher or equal rank bump in a previous commit\n"
			continue;
		fi

		$(MAKE) bump-module-version module=$$dependant_module level=patch;
	done

msg-to-level:
	@if echo "$(msg)" | grep -qE '^[^:]+!:'; then
		echo major
	elif echo "$(msg)" | grep -qE '^feat(\(.+\))?:'; then
		echo minor
	elif echo "$(msg)" | grep -qE '^(fix|build|refactor|deps)(\(.+\))?:'; then
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

files-touch-root:
	@printf '%b\n' "$(files)" | tr ' ' '\n' | grep -qE '^(pom\.xml|Dockerfile(\..*)?$$)' && echo "true" || echo "false"

files-touch-module:
	@if [ "$(module)" = "." ]; then
		$(MAKE) -s files-touch-root files="$(files)"
		exit 0
	fi

	printf '%b\n' "$(files)" | tr ' ' '\n' | grep -q "^$(module)/" && echo "true" || echo "false"

is-level-upgrade:
	@current_level=$$(grep "^$(module)=" .release-plan 2>/dev/null | cut -d= -f2)

	current_level_rank=$$($(MAKE) -s level-to-num level=$${current_level:-none})
	new_level_rank=$$($(MAKE) -s level-to-num level=$(level))

	if [ "$$new_level_rank" -gt "$$current_level_rank" ]; then
		echo "true"
		exit 0
	fi

	echo "false"

on-commit:
	@if [ -z "$(msg)" ] || [ -z "$(files)" ]; then
		printf "\nMissing required params, usage:\n\n";
		printf "make on-commit msg='commit-msg' files='file-path1.txt file/path2.xml'\n\n";
		exit 0;
	fi;

	@level=$$($(MAKE) -s msg-to-level msg="$(msg)")

	if [ "$$level" = "none" ]; then
		printf "Skipping version bumps: commit message does not require one.\n";
		exit 0
	fi

	printf "Planning version bumps for level <$$level>\n"

	for module in $$($(MAKE) -s list-modules); do
		printf "\n================================================================================="
		printf "\nEvaluating module <$$module>\n"

		if [ "$$($(MAKE) -s files-touch-module module=$$module files="$(files)")" = "false" ]; then
			printf "Skipping module <$$module> since no changes have been performed on it\n"
			continue
		fi

		if [ "$$($(MAKE) -s is-level-upgrade module=$$module level=$$level)" = "false" ]; then
			printf "Skipping module <$$module> since it already received a higher or equal rank bump in a previous commit\n"
			continue
		fi

		$(MAKE) bump-module-version module=$$module level=$$level
	done

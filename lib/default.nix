{ lib, inputs }:

let
  inherit (builtins)
    attrNames
    elem
    filter
    foldl'
    hasAttr
    hashString
    isBool
    isFunction
    isList
    match
    pathExists
    readDir
    readFile
    substring
    ;

  inherit (lib)
    concatMap
    concatMapStringsSep
    filterAttrs
    mapAttrs
    unique
    ;

  inherit (lib.strings)
    hasInfix
    hasPrefix
    hasSuffix
    ;

  isUnsafeRelPath = rel:
    hasPrefix "/" rel
    || rel == ".."
    || hasPrefix "../" rel
    || hasInfix "/../" rel
    || hasSuffix "/.." rel;

  assertSafeRelPath = ctx: rel:
    if isUnsafeRelPath rel then
      throw "agent-skills: ${ctx} '${rel}' must be relative and must not traverse outside the source root"
    else rel;

  # Shared bash helper injected into both the local-install and sync scripts.
  # Some destinations are populated by previous `copy-tree` runs that copied
  # from the read-only Nix store, leaving the tree non-writable. rsync needs
  # write permission to update those trees, so chmod before syncing.
  ensureWritableTreeBash = ''
    ensure_writable_tree() {
      local path="$1"
      if [ -e "$path" ] && [ ! -L "$path" ]; then
        chmod -R u+w "$path"
      fi
    }
  '';

  # Resolve the root path for a source, preferring an explicit path and
  # falling back to a flake input name.
  resolveSourceRoot = name: cfg:
    if (cfg.path or null) != null then cfg.path else
    if (cfg.input or null) != null then
      if inputs ? ${cfg.input} then inputs.${cfg.input}.outPath
      else throw "agent-skills: source ${name} refers to unknown input ${cfg.input}"
    else throw "agent-skills: source ${name} must set either `path` or `input`";

  # Validate skill IDs so we do not create unsafe paths.
  assertSkillId = id:
    if hasPrefix "/" id || hasInfix ".." id then
      throw "agent-skills: invalid skill id ${id} (must not start with '/' or contain '..')"
    else id;

  prefixSkillId = prefix: baseId:
    let
      validatedBaseId = assertSkillId baseId;
      validatedPrefix =
        if prefix == null || prefix == "" then null
        else
          let checkedPrefix = assertSkillId prefix;
          in
          if hasSuffix "/" checkedPrefix then
            throw "agent-skills: invalid source idPrefix ${checkedPrefix} (must not end with '/')"
          else checkedPrefix;
    in
    assertSkillId (
      if validatedPrefix == null then validatedBaseId
      else "${validatedPrefix}/${validatedBaseId}"
    );

  appendRelPath = root: rel:
    if rel == "" || rel == "." then "${root}" else "${root}/${rel}";

  sourceRelPathFor = skill:
    let rel = skill.sourceRelPath or (skill.relPath or ".");
    in if rel == "." then "" else rel;

  sourceRootFor = skill: skill.sourceRoot or skill.absPath;

  # Stable name keeps aliased declarations of the same dir collapsing to one
  # store path, which is what safeSourceRoots' memoisation relies on.
  sourceRootStorePath = skill:
    builtins.path {
      path = sourceRootFor skill;
      name = "agent-skills-source";
    };

  # hashString strips string context; `baseNameOf storePath` would smuggle a
  # store-path reference into the derivation name, which Nix forbids.
  sourceRootKey = storePath:
    substring 0 32 (hashString "sha256" (toString storePath));

  # Recursively search for SKILL.md directories up to `maxDepth`.
  # null = unlimited (capped internally at 100 to guard against symlink loops).
  discoverSource = name: cfg:
    let
      subdir = assertSafeRelPath "source ${name} subdir" (cfg.subdir or ".");
      skillsRoot' = resolveSourceRoot name cfg + "/${subdir}";
      skillsRoot = if !pathExists skillsRoot' then
        throw "agent-skills: source ${name} subdir ${toString skillsRoot'} does not exist"
      else skillsRoot';

      idPrefix = cfg.idPrefix or null;
      maxDepth = cfg.filter.maxDepth or null;
      nameRegex = cfg.filter.nameRegex or null;

      scan = path: relParts: depth:
        let
          entries = readDir path;
          relPath = lib.concatStringsSep "/" relParts;
          hasSkill = entries ? "SKILL.md";
          include = hasSkill && (nameRegex == null || match nameRegex relPath != null);
          current =
            if include then [
              {
                id = prefixSkillId idPrefix (if relPath == "" then name else relPath);
                source = name;
                relPath = relPath;
                sourceRoot = skillsRoot;
                sourceRelPath = relPath;
                absPath = path;
                meta = {};
              }
            ] else [];

          dirs = concatMap (n:
            if entries.${n} == "directory" || entries.${n} == "symlink" then [ n ] else []
          ) (attrNames entries);

          effectiveMax = if maxDepth == null then 100 else maxDepth;
          deeper =
            if depth < effectiveMax then
              concatMap (n: scan (path + "/${n}") (relParts ++ [ n ]) (depth + 1)) dirs
            else [];
        in current ++ deeper;

      collected = scan skillsRoot [] 0;
    in
    lib.listToAttrs (map (skill: {
      name = skill.id;
      value = skill;
    }) collected);

  # Merge catalogs across sources, enforcing unique IDs.
  discoverCatalog = sources:
    let
      addSource = acc: name: cfg:
        let local = discoverSource name cfg;
        in lib.attrsets.foldlAttrs
          (inner: id: skill:
            if inner ? ${id} then
              throw "agent-skills: duplicate skill id '${id}' found in source '${skill.source}' (${toString skill.absPath}) and source '${inner.${id}.source}' (${toString inner.${id}.absPath})"
            else inner // { ${id} = skill; }
          )
          acc
          local;
    in lib.attrsets.foldlAttrs addSource {} sources;

  # Build allowlist from enableAll + explicit enable list.
  allowlistFor = { catalog, sources, enableAll ? false, enable ? [] }:
    let
      enableAllSources =
        if isList enableAll then enableAll else [];
      enableAllAllSources =
        if isBool enableAll then enableAll else false;
      _ =
        let
          unknown = filter (name: !(hasAttr name sources)) enableAllSources;
        in
        if unknown != [] then
          throw "agent-skills: skills.enableAll refers to unknown sources: ${lib.concatStringsSep ", " unknown}"
        else null;
      sourceAllowlist =
        concatMap (sourceName:
          attrNames (filterAttrs (_: skill: skill.source == sourceName) catalog)
        ) enableAllSources;
    in
    unique (
      (if enableAllAllSources then attrNames catalog else [])
      ++ sourceAllowlist
      ++ enable
    );

  # Get binary info for a package (name, store path, and whether it has multiple binaries)
  getPkgBinInfo = pkg:
    let
      _ =
        if builtins.isDerivation pkg then true
        else throw "agent-skills: packages entries must be derivations, got ${builtins.typeOf pkg}";
      name = pkg.pname or pkg.name or "unknown";
      binDir = "${pkg}/bin";
      singleBin = "${binDir}/${name}";
      hasBinDir = pathExists binDir;
      hasSingleBin = pathExists singleBin;
      # List all binaries in the bin directory
      binEntries = if hasBinDir then attrNames (readDir binDir) else [];
      binCount = builtins.length binEntries;
      # Only use single binary if it exists AND is the only binary
      useSingleBin = hasSingleBin && binCount == 1;
    in {
      inherit name;
      path = if useSingleBin then singleBin else if hasBinDir then binDir else "${pkg}";
      isDir = hasBinDir && !useSingleBin;
      binaries = if binCount > 1 then binEntries else [];
    };

  # Generate markdown table for packages (using local paths)
  mkPackagesTable = packages:
    if packages == [] then ""
    else
      let
        header = ''
## Dependencies

| Package | Path |
|---------|------|
'';
        rows = concatMapStringsSep "\n" (pkg:
          let
            info = getPkgBinInfo pkg;
            localPath = if info.isDir then "./${info.name}/" else "./${info.name}";
            note = if info.isDir && info.binaries != []
              then " (contains: ${lib.concatStringsSep ", " (lib.take 5 info.binaries)}${if builtins.length info.binaries > 5 then ", ..." else ""})"
              else "";
          in "| ${info.name} | `${localPath}`${note} |"
        ) packages;
      in header + rows + "\n\n";

  # Rewrite single-binary package commands to ./command paths in content.
  rewriteCommandPaths = content: packages:
    let
      allBinNames = lib.unique (concatMap (pkg:
        let info = getPkgBinInfo pkg;
        in if info.isDir then [] else [ info.name ]
      ) packages);
    in
    if allBinNames == [] then content
    else
      let
        rewritten = builtins.replaceStrings
          allBinNames
          (map (name: "./${name}") allBinNames)
          content;
        fixed = builtins.replaceStrings
          (map (name: "././${name}") allBinNames)
          (map (name: "./${name}") allBinNames)
          rewritten;
      in fixed;

  # Build selection from allowlist + explicit skills.
  selectSkills = { catalog, allowlist ? [], skills ? {}, sources }:
    let
      allowlisted = lib.listToAttrs (map (id: {
        name = id;
        value =
          if catalog ? ${id} then catalog.${id}
          else throw "agent-skills: allowlist refers to unknown skill ${id}";
      }) allowlist);

      explicit = filterAttrs (_: cfg: cfg.enable or true) skills;

      fromExplicit = mapAttrs (name: cfg:
        let
          srcName = cfg.from or (throw "agent-skills: skill ${name} must set `from`");
          sourceCfg =
            if sources ? ${srcName} then sources.${srcName}
            else throw "agent-skills: skill ${name} references missing source ${srcName}";
          srcRoot = resolveSourceRoot srcName sourceCfg;
          subdir = assertSafeRelPath "source ${srcName} subdir" (sourceCfg.subdir or ".");
          sourceRoot = if subdir == "." then srcRoot else srcRoot + "/${subdir}";
          rel' = cfg.path or name;
          rel = if rel' == "." then "." else assertSafeRelPath "skill ${name} path" rel';
          sourceRelPath = if rel == "." then "" else rel;
          absPath =
            if sourceRelPath == "" then sourceRoot
            else sourceRoot + "/${sourceRelPath}";
          validated =
            if !pathExists absPath then
              throw "agent-skills: skill ${name} path ${absPath} does not exist"
            else if !pathExists (absPath + "/SKILL.md") then
              throw "agent-skills: skill ${name} at ${absPath} is missing SKILL.md"
            else if cfg ? transform && cfg.transform != null && !isFunction cfg.transform then
              throw "agent-skills: skill ${name} transform must be a function, got ${builtins.typeOf cfg.transform}"
            else true;
          id = assertSkillId (cfg.rename or name);
        in assert validated; {
          inherit id absPath;
          relPath = rel;
          inherit sourceRoot sourceRelPath;
          source = srcName;
          meta = cfg.meta or {};
          transform = cfg.transform or null;
          rewriteCommands = if cfg ? rewriteCommands then cfg.rewriteCommands else true;
          packages = cfg.packages or [];
        }
      ) explicit;

    in
    lib.attrsets.foldlAttrs
      (acc: id: skill:
        if acc ? ${id} then
          throw "agent-skills: skill id collision for ${id}"
        else acc // { ${id} = skill // { inherit id; }; }
      )
      allowlisted
      fromExplicit;

  # Filter targets by enabled flag and system selector.
  targetsFor = { targets, system }:
    filterAttrs (_: t:
      let systems = t.systems or [];
      in (t.enable or true) && (systems == [] || elem system systems)
    ) targets;

  # Materialize bundle in the store, preserving nested paths.
  mkBundle = { pkgs, selection, name ? "agent-skills-bundle" }:
    let
      skills = map (id: selection.${id} // { inherit id; }) (attrNames selection);
      # --safe-links drops symlinks whose textual target escapes the root;
      # the find pass cleans up chains left dangling by that drop (a -> b -> outside where b was already removed).
      mkSafeSourceRoot = storePath: key:
        pkgs.runCommand "agent-skills-source-${key}-safe" { preferLocalBuild = true; } ''
          mkdir -p "$out"
          ${pkgs.rsync}/bin/rsync -a --safe-links ${storePath}/ "$out"/
          # rsync inherited the store's read-only perms; relax so find can delete.
          chmod -R u+w "$out"
          ${pkgs.findutils}/bin/find "$out" -xtype l -delete
        '';
      safeSourceRoots = foldl'
        (acc: skill:
          let
            storePath = sourceRootStorePath skill;
            key = sourceRootKey storePath;
          in
          if acc ? ${key} then acc
          else acc // { ${key} = mkSafeSourceRoot storePath key; })
        {}
        skills;
      buildCommands = concatMapStringsSep "\n" (skill:
        let
          hasTransform = skill ? transform && skill.transform != null && isFunction skill.transform;
          hasPackages = (skill.packages or []) != [];
          needsCustomisation = hasTransform || hasPackages;
          safeRoot = safeSourceRoots.${sourceRootKey (sourceRootStorePath skill)};
          sourceRelPath = sourceRelPathFor skill;
          skillPath = appendRelPath safeRoot sourceRelPath;
          validateSkillPath = ''
          if [ ! -f ${lib.escapeShellArg "${skillPath}/SKILL.md"} ]; then
            echo ${lib.escapeShellArg "agent-skills: selected skill ${skill.id} is missing SKILL.md in the safe source tree"} >&2
            echo ${lib.escapeShellArg "agent-skills: this usually means the skill directory is a symlink escaping the declared source root"} >&2
            exit 1
          fi
          '';

          originalContent = readFile "${skillPath}/SKILL.md";
          packagesTable = mkPackagesTable (skill.packages or []);

          # Optionally rewrite single-binary command names to ./command paths.
          hasRewrite = (if skill ? rewriteCommands then skill.rewriteCommands else true) && hasPackages;
          rewrittenContent =
            if hasRewrite then rewriteCommandPaths originalContent (skill.packages or [])
            else originalContent;

          # Apply transform function or use default (original + dependencies at end)
          # This preserves frontmatter at the start of the file
          transformedContent =
            if hasTransform then
              skill.transform { original = rewrittenContent; dependencies = packagesTable; }
            else
              rewrittenContent + "\n" + packagesTable;
        in
        if needsCustomisation then
          let
            # Generate symlink commands for packages
            pkgLinks = concatMapStringsSep "\n" (pkg:
              let info = getPkgBinInfo pkg;
              in ''ln -s "${info.path}" "$out/$dest/${info.name}"''
            ) (skill.packages or []);
          in ''
          ${validateSkillPath}
          dest=${lib.escapeShellArg skill.id}
          mkdir -p "$out/$dest"
          # Link all files except SKILL.md
          for f in ${lib.escapeShellArg skillPath}/* ${lib.escapeShellArg skillPath}/*.; do
            fname="$(basename "$f")"
            if [ "$fname" != "SKILL.md" ]; then
              ln -s "$f" "$out/$dest/$fname"
            fi
          done
          # Link package binaries
          ${pkgLinks}
          # Create transformed SKILL.md
          cat > "$out/$dest/SKILL.md" <<'SKILL_EOF'
${transformedContent}
SKILL_EOF
        '' else ''
          ${validateSkillPath}
          dest=${lib.escapeShellArg skill.id}
          mkdir -p "$out/$(dirname "$dest")"
          ln -s ${lib.escapeShellArg skillPath} "$out/$dest"
        '') skills;
    in
    pkgs.runCommand name { preferLocalBuild = true; } ''
      mkdir -p "$out"
      ${buildCommands}
    '';

  # Render catalog in a stable, JSON-friendly form.
  catalogJson = catalog:
    lib.mapAttrs (_: skill: {
      source = skill.source;
      relPath = skill.relPath;
      absPath = skill.absPath;
      meta = skill.meta or {};
    }) catalog;

  # Default global targets for user-level installation.
  # Targets are opt-in by default; enable explicitly per target.
  # Canonical path docs live in README.md#default-target-paths.
  defaultTargets = {
    agents = {
      dest = "$HOME/.agents/skills";
      structure = "symlink-tree";
      enable = false;
      systems = [];
    };
    codex = {
      dest = "\${CODEX_HOME:-$HOME/.codex}/skills";
      structure = "symlink-tree";
      enable = false;
      systems = [];
    };
    opencode = {
      dest = "$HOME/.config/opencode/skills";
      structure = "symlink-tree";
      enable = false;
      systems = [];
    };
    claude = {
      dest = "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills";
      structure = "symlink-tree";
      enable = false;
      systems = [];
    };
    copilot = {
      dest = "$HOME/.copilot/skills";
      structure = "symlink-tree";
      enable = false;
      systems = [];
    };
    cursor = {
      dest = "$HOME/.cursor/skills";
      structure = "symlink-tree";
      enable = false;
      systems = [];
    };
    windsurf = {
      dest = "$HOME/.codeium/windsurf/skills";
      structure = "symlink-tree";
      enable = false;
      systems = [];
    };
    antigravity = {
      dest = "$HOME/.gemini/antigravity/skills";
      structure = "symlink-tree";
      enable = false;
      systems = [];
    };
    gemini = {
      dest = "$HOME/.gemini/skills";
      structure = "symlink-tree";
      enable = false;
      systems = [];
    };
    pi = {
      dest = "$HOME/.pi/agent/skills";
      structure = "symlink-tree";
      enable = false;
      systems = [];
    };
  };

  # Default local targets for project-local skill installation.
  # Targets are opt-in by default; enable explicitly per target.
  # Uses relative paths for project-local installation (not global env vars).
  defaultLocalTargets = {
    agents = { dest = ".agents/skills"; structure = "copy-tree"; enable = false; systems = []; };
    codex = { dest = ".codex/skills"; structure = "copy-tree"; enable = false; systems = []; };
    opencode = { dest = ".opencode/skills"; structure = "copy-tree"; enable = false; systems = []; };
    claude = { dest = ".claude/skills"; structure = "copy-tree"; enable = false; systems = []; };
    copilot = { dest = ".github/skills"; structure = "copy-tree"; enable = false; systems = []; };
    cursor = { dest = ".cursor/skills"; structure = "copy-tree"; enable = false; systems = []; };
    windsurf = { dest = ".windsurf/skills"; structure = "copy-tree"; enable = false; systems = []; };
    antigravity = { dest = ".agent/skills"; structure = "copy-tree"; enable = false; systems = []; };
    gemini = { dest = ".gemini/skills"; structure = "copy-tree"; enable = false; systems = []; };
    pi = { dest = ".pi/skills"; structure = "copy-tree"; enable = false; systems = []; };
  };

  # Default exclude patterns for rsync synchronization.
  # Excludes "/.system" (root-level only) to allow agents (Codex, etc.) to manage their own system skills.
  # The leading "/" ensures only the top-level .system is excluded, not .system dirs inside skills.
  defaultExcludePatterns = [ "/.system" ];

  # Create a local install script for use in consumer flakes.
  # This allows projects to install skills to their local directory.
  # Respects target enable/system filters and structure (link/symlink-tree/copy-tree).
  mkLocalInstallScript = { pkgs, bundle, targets ? defaultLocalTargets, excludePatterns ? defaultExcludePatterns }:
    let
      activeTargets = targetsFor { inherit targets; system = pkgs.stdenv.hostPlatform.system; };
      targetsList = lib.mapAttrsToList (name: t:
        let
          structure = t.structure or "copy-tree";
          dest = t.dest;
        in
          ''"${name}|${structure}|${dest}"''
      ) activeTargets;
      targetsArray = lib.concatStringsSep "\n  " targetsList;
      excludeFlags = concatMapStringsSep " " (p: "--exclude='${p}'") excludePatterns;
    in
    pkgs.writeShellApplication {
      name = "skills-install-local";
      runtimeInputs = [ pkgs.rsync pkgs.coreutils ];
      text = ''
        root="''${AGENT_SKILLS_ROOT:-$PWD}"
        bundle=${bundle}
        if [ ! -d "$bundle" ]; then
          echo "agent-skills: bundle not built" >&2
          exit 1
        fi

        targets=(
          ${targetsArray}
        )

        override=()
        if [ -n "''${AGENT_SKILLS_LOCAL_DESTS:-}" ]; then
          read -r -a override <<< "''${AGENT_SKILLS_LOCAL_DESTS:-}"
        fi

        # Check if path is safe to overwrite for the requested structure.
        is_safe_to_overwrite() {
          local path="$1"
          local structure="$2"
          if [ ! -e "$path" ]; then
            return 0  # Doesn't exist, safe
          fi
          if [ -L "$path" ]; then
            local target
            target="$(readlink -f "$path")"
            if [[ "$target" == /nix/store/* ]]; then
              return 0  # Symlink to Nix store, safe
            fi
            return 1
          fi

          case "$structure" in
            copy-tree)
              # copy-tree is designed for mutable local directories.
              if [ -d "$path" ]; then
                return 0
              fi
              ;;
          esac

          return 1  # Not safe
        }

        ${ensureWritableTreeBash}

        for i in "''${!targets[@]}"; do
          IFS="|" read -r name structure dest <<< "''${targets[$i]}"
          if [ -n "''${override[$i]:-}" ]; then
            dest="''${override[$i]}"
          fi
          if [ -z "$dest" ]; then
            continue
          fi
          full_dest="$root/$dest"

          if ! is_safe_to_overwrite "$full_dest" "$structure"; then
            echo "agent-skills: $full_dest exists and is not a Nix-managed path" >&2
            echo "agent-skills: skipping to avoid overwriting user data" >&2
            echo "agent-skills: remove manually or set AGENT_SKILLS_FORCE=1 to overwrite" >&2
            if [ "''${AGENT_SKILLS_FORCE:-}" != "1" ]; then
              continue
            fi
            echo "agent-skills: AGENT_SKILLS_FORCE=1 set, overwriting anyway" >&2
          fi

          case "$structure" in
            link)
              mkdir -p "$(dirname "$full_dest")"
              rm -rf "$full_dest"
              ln -s "$bundle" "$full_dest"
              ;;
            symlink-tree)
              if [ -L "$full_dest" ]; then
                rm -rf "$full_dest"
              fi
              mkdir -p "$full_dest"
              ensure_writable_tree "$full_dest"
              ${pkgs.rsync}/bin/rsync -a --delete ${excludeFlags} "$bundle/" "$full_dest/"
              # Ensure dest is writable so agents can create subdirectories (e.g., .system)
              chmod u+w "$full_dest"
              ;;
            copy-tree)
              if [ -L "$full_dest" ]; then
                rm -rf "$full_dest"
              fi
              mkdir -p "$full_dest"
              ensure_writable_tree "$full_dest"
              ${pkgs.rsync}/bin/rsync -aL --delete ${excludeFlags} "$bundle/" "$full_dest/"
              # Ensure dest is writable so agents can create subdirectories (e.g., .system)
              chmod u+w "$full_dest"
              ;;
            *)
              echo "agent-skills: unknown structure '$structure' for target '$name'" >&2
              exit 1
              ;;
          esac

          echo "agent-skills: installed to $full_dest"
        done

        if [ "''${#override[@]}" -gt "''${#targets[@]}" ]; then
          for ((i=''${#targets[@]}; i<''${#override[@]}; i++)); do
            dest="''${override[$i]}"
            if [ -z "$dest" ]; then
              continue
            fi
            full_dest="$root/$dest"
            if ! is_safe_to_overwrite "$full_dest" "copy-tree"; then
              echo "agent-skills: $full_dest exists and is not a Nix-managed path" >&2
              echo "agent-skills: skipping to avoid overwriting user data" >&2
              echo "agent-skills: remove manually or set AGENT_SKILLS_FORCE=1 to overwrite" >&2
              if [ "''${AGENT_SKILLS_FORCE:-}" != "1" ]; then
                continue
              fi
              echo "agent-skills: AGENT_SKILLS_FORCE=1 set, overwriting anyway" >&2
            fi
            if [ -L "$full_dest" ]; then
              rm -rf "$full_dest"
            fi
            mkdir -p "$full_dest"
            ensure_writable_tree "$full_dest"
            ${pkgs.rsync}/bin/rsync -aL --delete ${excludeFlags} "$bundle/" "$full_dest/"
            # Ensure dest is writable so agents can create subdirectories (e.g., .system)
            chmod u+w "$full_dest"
            echo "agent-skills: installed to $full_dest"
          done
        fi
      '';
    };

  # Create a sync script for user-level installation targets.
  # Respects target enable/system filters and structure (link/symlink-tree/copy-tree).
  # Optionally allows overriding destinations via an environment variable.
  mkSyncScript = {
    pkgs,
    bundle,
    targets,
    system ? pkgs.stdenv.hostPlatform.system,
    allowOverrides ? false,
    overrideEnvVar ? "AGENT_SKILLS_DESTS",
    overrideStructure ? "symlink-tree",
    excludePatterns ? defaultExcludePatterns,
  }:
    let
      activeTargets = targetsFor { inherit targets system; };
      targetsList = lib.mapAttrsToList (name: t:
        let
          structure = t.structure or "symlink-tree";
          dest = t.dest;
        in
          ''"${name}|${structure}|${dest}"''
      ) activeTargets;
      targetsArray = lib.concatStringsSep "\n  " targetsList;
      excludeFlags = concatMapStringsSep " " (p: "--exclude='${p}'") excludePatterns;
      overrideVar = "\${" + overrideEnvVar + ":-}";
      overrideSnippet = if allowOverrides then ''
        if [ -n "${overrideVar}" ]; then
          read -r -a override <<< "${overrideVar}"
          for dest in "''${override[@]}"; do
            if [ -z "$dest" ]; then continue; fi
            sync_dest "$dest" "${overrideStructure}" "override"
          done
          exit 0
        fi
      '' else "";
    in ''
      bundle=${bundle}
      if [ ! -d "$bundle" ]; then
        echo "agent-skills: bundle not built" >&2
        exit 1
      fi

      ${ensureWritableTreeBash}

      sync_dest() {
        local dest="$1"
        local structure="$2"
        local name="$3"
        case "$structure" in
          link)
            mkdir -p "$(dirname "$dest")"
            rm -rf "$dest"
            ln -s "$bundle" "$dest"
            ;;
          symlink-tree)
            mkdir -p "$dest"
            ensure_writable_tree "$dest"
            ${pkgs.rsync}/bin/rsync -a --delete ${excludeFlags} "$bundle/" "$dest/"
            # Ensure dest is writable so agents can create subdirectories (e.g., .system)
            chmod u+w "$dest"
            ;;
          copy-tree)
            mkdir -p "$dest"
            ensure_writable_tree "$dest"
            ${pkgs.rsync}/bin/rsync -aL --delete ${excludeFlags} "$bundle/" "$dest/"
            # Ensure dest is writable so agents can create subdirectories (e.g., .system)
            chmod u+w "$dest"
            ;;
          *)
            echo "agent-skills: unknown structure '$structure' for target '$name'" >&2
            exit 1
            ;;
        esac
      }

      ${overrideSnippet}

      targets=(
        ${targetsArray}
      )

      for entry in "''${targets[@]}"; do
        IFS="|" read -r name structure dest <<< "$entry"
        if [ -z "$dest" ]; then continue; fi
        sync_dest "$dest" "$structure" "$name"
      done
    '';

  # Create a shellHook string for use in devShells.
  # Automatically installs skills when entering the dev shell.
  mkShellHook = { pkgs, bundle, targets ? defaultLocalTargets, excludePatterns ? defaultExcludePatterns }:
    let
      installScript = mkLocalInstallScript { inherit pkgs bundle targets excludePatterns; };
    in ''
      ${installScript}/bin/skills-install-local
    '';

in
{
  discoverCatalog = discoverCatalog;
  selectSkills = selectSkills;
  allowlistFor = allowlistFor;
  targetsFor = targetsFor;
  mkBundle = mkBundle;
  mkPackagesTable = mkPackagesTable;
  rewriteCommandPaths = rewriteCommandPaths;
  getPkgBinInfo = getPkgBinInfo;
  catalogJson = catalogJson;
  mkLocalInstallScript = mkLocalInstallScript;
  mkSyncScript = mkSyncScript;
  mkShellHook = mkShellHook;
  defaultTargets = defaultTargets;
  defaultLocalTargets = defaultLocalTargets;
  defaultExcludePatterns = defaultExcludePatterns;
}

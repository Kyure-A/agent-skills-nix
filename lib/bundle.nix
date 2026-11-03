{ lib, sources, selectionLib }:

let
  inherit (builtins)
    attrNames
    foldl'
    isFunction
    pathExists
    readDir
    readFile
    ;

  inherit (lib)
    concatMap
    concatMapStringsSep
    unique
    ;

  inherit (sources)
    appendRelPath
    sourceRelPathFor
    sourceRootFor
    sourceRootKey
    ;

  # Get binary info for a package (name, store path, and whether it has multiple binaries)
  getPkgBinInfo = pkg:
    let
      validPackage =
        if lib.isDerivation pkg then true
        else throw "agent-skills: packages entries must be derivations, got ${builtins.typeOf pkg}";
      name = pkg.pname or pkg.name or "unknown";
      binDir = "${pkg}/bin";
      singleBin = "${binDir}/${name}";
      hasBinDir = pathExists binDir;
      hasSingleBin = pathExists singleBin;
      # List all binaries in the bin directory
      binEntries = if hasBinDir then attrNames (readDir binDir) else [ ];
      binCount = builtins.length binEntries;
      # Only use single binary if it exists AND is the only binary
      useSingleBin = hasSingleBin && binCount == 1;
    in
    assert validPackage;
    {
      inherit name;
      path = if useSingleBin then singleBin else if hasBinDir then binDir else "${pkg}";
      isDir = hasBinDir && !useSingleBin;
      binaries = if binCount > 1 then binEntries else [ ];
    };

  # Generate markdown table for packages (using local paths)
  mkPackagesTable = packages:
    if packages == [ ] then ""
    else
      let
        header = ''
          ## Dependencies

          | Package | Path |
          |---------|------|
        '';
        rows = concatMapStringsSep "\n"
          (pkg:
            let
              info = getPkgBinInfo pkg;
              localPath = if info.isDir then "./${info.name}/" else "./${info.name}";
              note =
                if info.isDir && info.binaries != [ ]
                then " (contains: ${lib.concatStringsSep ", " (lib.take 5 info.binaries)}${if builtins.length info.binaries > 5 then ", ..." else ""})"
                else "";
            in
            "| ${info.name} | `${localPath}`${note} |"
          )
          packages;
      in
      header + rows + "\n\n";

  # Rewrite single-binary package commands to ./command paths in content.
  rewriteCommandPaths = content: packages:
    let
      allBinNames = lib.unique (concatMap
        (pkg:
          let info = getPkgBinInfo pkg;
          in if info.isDir then [ ] else [ info.name ]
        )
        packages);
    in
    if allBinNames == [ ] then content
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
      in
      fixed;

  # Packages listed by a skill are only realised at build time, so anything
  # that depends on their bin/ layout (links, the dependencies table, command
  # rewriting) must be decided there too. Inspecting them during evaluation
  # would be import-from-derivation and build every package mid-eval.
  # Evaluation leaves these placeholders, which the build script resolves.
  dependenciesPlaceholder = "@agent-skills-dependencies@";
  commandPlaceholder = i: "@agent-skills-command-${toString i}@";
  prefixedCommandPlaceholder = i: "@agent-skills-prefixed-command-${toString i}@";

  # Mirrors getPkgBinInfo, mkPackagesTable and rewriteCommandPaths, but runs
  # at build time. Expects $out/$dest/SKILL.md to exist and appends this
  # package's row to $dependencies.
  mkPackageCommands = i: pkg:
    let
      validPackage =
        if lib.isDerivation pkg then true
        else throw "agent-skills: packages entries must be derivations, got ${builtins.typeOf pkg}";
      name = pkg.pname or pkg.name or "unknown";
      pkgPath = lib.escapeShellArg "${pkg}";
      binDir = lib.escapeShellArg "${pkg}/bin";
      escapedName = lib.escapeShellArg name;
    in
    assert validPackage;
    ''
      bins=()
      if [ -d ${binDir} ]; then
        while IFS= read -r bin; do bins+=("$bin"); done < <(LC_ALL=C ls -A ${binDir})
      fi
      if [ -e ${binDir}/${escapedName} ] && [ "''${#bins[@]}" -eq 1 ]; then
        target=${binDir}/${escapedName}
        isDir=
      elif [ -d ${binDir} ]; then
        target=${binDir}
        isDir=1
      else
        target=${pkgPath}
        isDir=
      fi
      ln -s "$target" "$out/$dest/"${escapedName}

      if [ -n "$isDir" ]; then
        note=
        if [ "''${#bins[@]}" -gt 1 ]; then
          shown=("''${bins[@]:0:5}")
          note=" (contains: $(IFS=,; echo "''${shown[*]}" | sed 's/,/, /g')"
          if [ "''${#bins[@]}" -gt 5 ]; then note="$note, ..."; fi
          note="$note)"
        fi
        dependencies+=$'\n'"| "${escapedName}" | \`./"${escapedName}"/\`$note |"
        command=${escapedName}
      else
        dependencies+=$'\n'"| "${escapedName}" | \`./"${escapedName}"\` |"
        command=./${escapedName}
      fi
      substituteInPlace "$out/$dest/SKILL.md" \
        --replace-quiet ${lib.escapeShellArg (commandPlaceholder i)} "$command" \
        --replace-quiet ${lib.escapeShellArg (prefixedCommandPlaceholder i)} ./${escapedName}
    '';

  # Materialize bundle in the store, preserving nested paths.
  mkBundle = { pkgs, selection, name ? "agent-skills-bundle" }:
    let
      skills = map
        (skill: skill // {
          agents = selectionLib.agentsFor skill.id skill;
        })
        (builtins.attrValues selection);
      hasTargetRestrictions = lib.any (skill: skill.agents != null) skills;
      skillTargetNames = unique (concatMap (skill: if skill.agents == null then [ ] else skill.agents) skills);
      # Share materialized skills (including transforms and dependencies) across
      # targets instead of dumping and sanitizing the same sources for each one.
      forTarget = target:
        let
          allowed = builtins.filter (skill: skill.agents == null || builtins.elem target skill.agents) skills;
        in
        if builtins.length allowed == builtins.length skills then result
        else
          pkgs.runCommand "${name}-filtered" { preferLocalBuild = true; } ''
            mkdir -p "$out"
            ${concatMapStringsSep "\n" (skill: ''
              dest=${lib.escapeShellArg skill.id}
              mkdir -p "$out/$(dirname "$dest")"
              ln -s ${lib.escapeShellArg "${result}/${skill.id}"} "$out/$dest"
            '') allowed}
          '';
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
      # Dump every unique source root to the store exactly once up front.
      # builtins.path re-streams its input to the daemon on every call (there
      # is no eval-time dedup for store-path inputs with a custom name), so
      # calling it per skill multiplied eval-time I/O by 2x the skill count.
      uniqueSourceRoots = unique (map sourceRootFor skills);
      dumpedRoots = map
        (root: builtins.path {
          path = root;
          name = "agent-skills-source";
        })
        uniqueSourceRoots;
      # Path equality tolerates derivation string context, unlike toString.
      storePathFor = skill:
        let
          i = lib.lists.findFirstIndex
            (root: root == sourceRootFor skill)
            null
            uniqueSourceRoots;
        in
        if i == null then
          throw "agent-skills: internal error: source root not memoized"
        else
          builtins.elemAt dumpedRoots i;
      safeSourceRoots = foldl'
        (acc: storePath:
          let
            key = sourceRootKey storePath;
          in
          acc // { ${key} = mkSafeSourceRoot storePath key; })
        { }
        dumpedRoots;
      buildCommands = concatMapStringsSep "\n"
        (skill:
          let
            hasTransform = skill ? transform && skill.transform != null && isFunction skill.transform;
            hasPackages = (skill.packages or [ ]) != [ ];
            needsCustomisation = hasTransform || hasPackages;
            safeRoot = safeSourceRoots.${sourceRootKey (storePathFor skill)};
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
            packages = skill.packages or [ ];
            packagesTable = if hasPackages then dependenciesPlaceholder else "";

            # Optionally rewrite package command names to ./command paths. Every
            # package name becomes a placeholder here; the build step turns it
            # back into the bare name for multi-binary packages. Already
            # prefixed names get their own placeholder so they never end up as
            # ././command.
            hasRewrite = (if skill ? rewriteCommands then skill.rewriteCommands else true) && hasPackages;
            commandNames = map (pkg: pkg.pname or pkg.name or "unknown") packages;
            indices = lib.range 0 (builtins.length packages - 1);
            rewrittenContent =
              if hasRewrite then
                builtins.replaceStrings
                  (map (name: "./${name}") commandNames ++ commandNames)
                  (map prefixedCommandPlaceholder indices ++ map commandPlaceholder indices)
                  originalContent
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
              pkgCommands = lib.concatStringsSep "\n" (lib.imap0 mkPackageCommands packages);
            in
            ''
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
                        # Create transformed SKILL.md
                        cat > "$out/$dest/SKILL.md" <<'SKILL_EOF'
              ${transformedContent}
              SKILL_EOF
                        # Link package binaries and resolve their placeholders
                        dependencies=
                        ${pkgCommands}
                        ${lib.optionalString hasPackages ''
                          substituteInPlace "$out/$dest/SKILL.md" \
                            --replace-quiet ${lib.escapeShellArg dependenciesPlaceholder} \
                            "## Dependencies"$'\n\n'"| Package | Path |"$'\n'"|---------|------|$dependencies"$'\n\n'
                        ''}
            '' else ''
            ${validateSkillPath}
            dest=${lib.escapeShellArg skill.id}
            mkdir -p "$out/$(dirname "$dest")"
            ln -s ${lib.escapeShellArg skillPath} "$out/$dest"
          '')
        skills;
      result = pkgs.runCommand name
        {
          preferLocalBuild = true;
          passthru = { inherit forTarget hasTargetRestrictions skillTargetNames; };
        } ''
        mkdir -p "$out"
        ${buildCommands}
      '';
    in
    result;
in
{
  inherit
    getPkgBinInfo
    mkBundle
    mkPackagesTable
    rewriteCommandPaths
    ;
}

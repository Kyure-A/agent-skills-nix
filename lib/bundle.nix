{ lib, sources }:

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
      _ =
        if builtins.isDerivation pkg then true
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
            packagesTable = mkPackagesTable (skill.packages or [ ]);

            # Optionally rewrite single-binary command names to ./command paths.
            hasRewrite = (if skill ? rewriteCommands then skill.rewriteCommands else true) && hasPackages;
            rewrittenContent =
              if hasRewrite then rewriteCommandPaths originalContent (skill.packages or [ ])
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
              pkgLinks = concatMapStringsSep "\n"
                (pkg:
                  let info = getPkgBinInfo pkg;
                  in ''ln -s "${info.path}" "$out/$dest/${info.name}"''
                )
                (skill.packages or [ ]);
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
          '')
        skills;
    in
    pkgs.runCommand name { preferLocalBuild = true; } ''
      mkdir -p "$out"
      ${buildCommands}
    '';
in
{
  inherit
    getPkgBinInfo
    mkBundle
    mkPackagesTable
    rewriteCommandPaths
    ;
}

{ lib, inputs }:

let
  sourceConfig = import ./source-config.nix { inherit lib; };
  inherit (sourceConfig) assertOnlyKeys assertSafeRelPath assertSkillId normalizeSourceConfig normalizeSources;

  inherit (builtins)
    attrNames
    hashString
    match
    pathExists
    readDir
    substring
    ;

  inherit (lib)
    concatMap
    ;

  # Resolve the root path for a source, preferring an explicit path and
  # falling back to a flake input name.
  resolveSourceRoot = name: cfg:
    if (cfg.path or null) != null then cfg.path else
    if (cfg.input or null) != null then
      if inputs ? ${cfg.input} then inputs.${cfg.input}.outPath
      else throw "agent-skills: source ${name} refers to unknown input ${cfg.input}"
    else throw "agent-skills: source ${name} must set either `path` or `input`";

  sourcePathFor = name: value:
    let
      cfg = normalizeSourceConfig name value;
      root = resolveSourceRoot name cfg;
      path = if cfg.subdir == "." then root else root + "/${cfg.subdir}";
    in
    if !pathExists path then
      throw "agent-skills: source ${name} subdir ${toString path} does not exist"
    else path;

  prefixSkillId = prefix: baseId:
    assertSkillId (if prefix == null then baseId else "${prefix}/${baseId}");

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
      skillsRoot = sourcePathFor name cfg;
      inherit (cfg) idPrefix;
      inherit (cfg.filter) maxDepth nameRegex;

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
                meta = { };
              }
            ] else [ ];

          dirs = concatMap
            (n:
              if entries.${n} == "directory" || entries.${n} == "symlink" then [ n ] else [ ]
            )
            (attrNames entries);

          effectiveMax = if maxDepth == null then 100 else maxDepth;
          deeper =
            if depth < effectiveMax then
              concatMap (n: scan (path + "/${n}") (relParts ++ [ n ]) (depth + 1)) dirs
            else [ ];
        in
        current ++ deeper;

      collected = scan skillsRoot [ ] 0;
    in
    lib.listToAttrs (map
      (skill: {
        name = skill.id;
        value = skill;
      })
      collected);

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
    in
    lib.attrsets.foldlAttrs addSource { } (normalizeSources sources);

  # Render catalog in a stable, JSON-friendly form.
  catalogJson = catalog:
    lib.mapAttrs
      (_: skill: {
        source = skill.source;
        relPath = skill.relPath;
        absPath = skill.absPath;
        meta = skill.meta or { };
      })
      catalog;
in
{
  inherit
    appendRelPath
    assertOnlyKeys
    assertSafeRelPath
    assertSkillId
    catalogJson
    discoverCatalog
    normalizeSources
    resolveSourceRoot
    sourcePathFor
    sourceRelPathFor
    sourceRootFor
    sourceRootKey
    sourceRootStorePath
    ;
}

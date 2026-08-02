{ lib, inputs }:

let
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
      skillsRoot =
        if !pathExists skillsRoot' then
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
    lib.attrsets.foldlAttrs addSource { } sources;

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
    assertSafeRelPath
    assertSkillId
    catalogJson
    discoverCatalog
    resolveSourceRoot
    sourceRelPathFor
    sourceRootFor
    sourceRootKey
    sourceRootStorePath
    ;
}

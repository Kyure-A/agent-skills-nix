{ lib, sources }:

let
  inherit (builtins)
    attrNames
    filter
    hasAttr
    isBool
    isFunction
    isList
    pathExists
    ;

  inherit (lib)
    concatMap
    filterAttrs
    mapAttrs
    unique
    ;

  inherit (sources)
    assertSafeRelPath
    assertSkillId
    resolveSourceRoot
    ;

  # Build allowlist from enableAll + explicit enable list.
  allowlistFor = { catalog, sources, enableAll ? false, enable ? [ ] }:
    let
      enableAllSources =
        if isList enableAll then enableAll else [ ];
      enableAllAllSources =
        if isBool enableAll then enableAll else false;
      _ =
        let
          unknown = filter (name: !(hasAttr name sources)) enableAllSources;
        in
        if unknown != [ ] then
          throw "agent-skills: skills.enableAll refers to unknown sources: ${lib.concatStringsSep ", " unknown}"
        else null;
      sourceAllowlist =
        concatMap
          (sourceName:
            attrNames (filterAttrs (_: skill: skill.source == sourceName) catalog)
          )
          enableAllSources;
    in
    unique (
      (if enableAllAllSources then attrNames catalog else [ ])
      ++ sourceAllowlist
      ++ enable
    );

  # Build selection from allowlist + explicit skills.
  selectSkills = { catalog, allowlist ? [ ], skills ? { }, sources }:
    let
      allowlisted = lib.listToAttrs (map
        (id: {
          name = id;
          value =
            if catalog ? ${id} then catalog.${id}
            else throw "agent-skills: allowlist refers to unknown skill ${id}";
        })
        allowlist);

      explicit = filterAttrs (_: cfg: cfg.enable or true) skills;

      fromExplicit = mapAttrs
        (name: cfg:
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
          in
          assert validated; {
            inherit id absPath;
            relPath = rel;
            inherit sourceRoot sourceRelPath;
            source = srcName;
            meta = cfg.meta or { };
            transform = cfg.transform or null;
            rewriteCommands = if cfg ? rewriteCommands then cfg.rewriteCommands else true;
            packages = cfg.packages or [ ];
          }
        )
        explicit;

    in
    lib.attrsets.foldlAttrs
      (acc: id: skill:
        if acc ? ${id} then
          throw "agent-skills: skill id collision for ${id}"
        else acc // { ${id} = skill // { inherit id; }; }
      )
      allowlisted
      fromExplicit;
in
{
  inherit allowlistFor selectSkills;
}

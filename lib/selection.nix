{ lib, sources }:

let
  inherit (builtins)
    attrNames
    filter
    hasAttr
    isAttrs
    isBool
    isFunction
    isList
    isString
    pathExists
    ;

  inherit (sources)
    assertOnlyKeys
    assertSafeRelPath
    assertSkillId
    normalizeSources
    sourcePathFor
    ;

  # null means unrestricted; an explicit empty allowlist selects no targets.
  agentsFor = name: skill:
    let agents = skill.agents or null;
    in
    if agents == null then null
    else if !isList agents || !(lib.all (agent: isString agent && agent != "") agents) then
      throw "agent-skills: skill ${name} agents must be null or a list of non-empty target names"
    else lib.unique agents;

  assertAttrs = context: value:
    if isAttrs value then value
    else throw "agent-skills: ${context} must be an attribute set";

  normalizeIds = context: ids:
    if !isList ids then
      throw "agent-skills: ${context} must be a list of skill IDs"
    else
      let checked = map assertSkillId ids;
      in builtins.deepSeq checked (lib.unique checked);

  # Resolve and validate IDs before returning the list, even if its caller only
  # inspects its length. Validation must not live in unused lazy bindings.
  catalogIds = context: catalog: ids:
    let
      checked = normalizeIds context ids;
      unknown = filter (id: !(hasAttr id catalog)) checked;
    in
    if unknown != [ ] then
      throw "agent-skills: ${context} refers to unknown skills: ${lib.concatStringsSep ", " unknown}"
    else checked;

  allowlistFor = { catalog, sources, enableAll ? false, enable ? [ ] }:
    let
      sourceConfigs = normalizeSources sources;
      checkedCatalog = assertAttrs "catalog" catalog;
      enableAllSources =
        if isBool enableAll then [ ]
        else if isList enableAll && builtins.all isString enableAll then
          let unknown = filter (name: !(hasAttr name sourceConfigs)) enableAll;
          in
          if unknown != [ ] then
            throw "agent-skills: skills.enableAll refers to unknown sources: ${lib.concatStringsSep ", " unknown}"
          else lib.unique enableAll
        else throw "agent-skills: skills.enableAll must be a boolean or a list of source names";
      sourceAllowlist = lib.concatMap
        (sourceName:
          attrNames (lib.filterAttrs (_: skill: skill.source == sourceName) checkedCatalog)
        )
        enableAllSources;
      selected =
        (if isBool enableAll && enableAll then attrNames checkedCatalog else [ ])
        ++ sourceAllowlist
        ++ normalizeIds "skills.enable" enable;
    in
    builtins.seq sourceConfigs (
      builtins.seq checkedCatalog (catalogIds "skills.enable" checkedCatalog selected)
    );

  # Disabled declarations need no source, but their enable flag must still be
  # well-typed. Enabled declarations become validated skill records.
  normalizeExplicit = sourceConfigs: name: value:
    let
      cfg = assertOnlyKeys "skill ${name}" [
        "enable"
        "from"
        "path"
        "rename"
        "meta"
        "transform"
        "rewriteCommands"
        "packages"
        "agents"
      ]
        value;
      enable = cfg.enable or true;
      srcName = cfg.from or null;
      sourceCfg =
        if !isString srcName || srcName == "" then
          throw "agent-skills: skill ${name} must set `from` to a source name"
        else if hasAttr srcName sourceConfigs then sourceConfigs.${srcName}
        else throw "agent-skills: skill ${name} references missing source ${srcName}";
      sourceRoot = sourcePathFor srcName sourceCfg;
      rawRel = assertSafeRelPath "skill ${name} path" (cfg.path or name);
      rel =
        if rawRel == "" then throw "agent-skills: skill ${name} path must not be empty; use '.' for the source root"
        else rawRel;
      sourceRelPath = if rel == "." then "" else rel;
      absPath =
        if sourceRelPath == "" then sourceRoot
        else sourceRoot + "/${sourceRelPath}";
      rename = cfg.rename or null;
      id = assertSkillId (if rename == null then name else rename);
      meta = assertAttrs "skill ${name} meta" (cfg.meta or { });
      transform = cfg.transform or null;
      rewriteCommands = cfg.rewriteCommands or true;
      packages = cfg.packages or [ ];
      agents = agentsFor name cfg;
      checked =
        if !pathExists absPath then
          throw "agent-skills: skill ${name} path ${toString absPath} does not exist"
        else if !pathExists (absPath + "/SKILL.md") then
          throw "agent-skills: skill ${name} at ${toString absPath} is missing SKILL.md"
        else if transform != null && !isFunction transform then
          throw "agent-skills: skill ${name} transform must be a function, got ${builtins.typeOf transform}"
        else if !isBool rewriteCommands then
          throw "agent-skills: skill ${name} rewriteCommands must be a boolean"
        else if !isList packages || !builtins.all lib.isDerivation packages then
          throw "agent-skills: skill ${name} packages must be a list of derivations"
        else builtins.seq agents true;
    in
    if !isBool enable then
      throw "agent-skills: skill ${name} enable must be a boolean"
    else if !enable then null
    else
      assert checked;
      builtins.seq id (builtins.seq meta {
        inherit id absPath sourceRoot sourceRelPath meta transform rewriteCommands packages agents;
        relPath = rel;
        source = srcName;
      });

  selectSkills = { catalog, allowlist ? [ ], skills ? { }, sources }:
    let
      sourceConfigs = normalizeSources sources;
      checkedCatalog = assertAttrs "catalog" catalog;
      checkedSkills = assertAttrs "skills" skills;
      ids = catalogIds "allowlist" checkedCatalog allowlist;
      allowlisted = map
        (id:
          let skill = assertAttrs "catalog skill ${id}" checkedCatalog.${id};
          in skill // { inherit id; }
        )
        ids;
      explicit = lib.filterAttrs (_: skill: skill != null)
        (lib.mapAttrs (normalizeExplicit sourceConfigs) checkedSkills);
      addSkill = acc: id: skill:
        if hasAttr id acc then
          throw "agent-skills: skill id collision for ${id}"
        else acc // { ${id} = skill // { inherit id; }; };
      selectedCatalog = lib.listToAttrs (map (skill: { name = skill.id; value = skill; }) allowlisted);
    in
    builtins.seq sourceConfigs (
      builtins.seq checkedCatalog (lib.foldlAttrs addSkill selectedCatalog explicit)
    );
in
{
  inherit agentsFor allowlistFor selectSkills;
}

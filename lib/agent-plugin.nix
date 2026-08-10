{ lib, sources }:

let
  inherit (builtins)
    attrNames
    elem
    isAttrs
    isList
    isPath
    isString
    length
    match
    stringLength
    ;

  inherit (lib)
    concatMapStringsSep
    unique
    ;

  inherit (sources)
    appendRelPath
    assertSafeRelPath
    sourceRelPathFor
    sourceRootFor
    ;

  fail = message: throw "agent-skills: mkAgentPlugin: ${message}";

  nonWhitespacePattern = ".*[^[:space:]].*";

  expect = condition: message: value:
    if condition then value else fail message;

  expectAttrs = label: value:
    expect (isAttrs value) "${label} must be an attribute set, got ${builtins.typeOf value}" value;

  expectString = label: value:
    expect
      (isString value && match nonWhitespacePattern value != null)
      "${label} must be a non-empty string"
      value;

  expectStringList = label: value:
    expect
      (isList value && builtins.all
        (item: isString item && match nonWhitespacePattern item != null)
        value)
      "${label} must be a list of non-empty strings"
      value;

  rejectUnknown = label: allowed: value:
    let
      unknown = builtins.filter (field: !(elem field allowed)) (attrNames value);
    in
    expect
      (unknown == [ ])
      "${label} contains unsupported fields: ${builtins.concatStringsSep ", " unknown}"
      value;

  pluginNamePattern = "^[a-z0-9]+(-[a-z0-9]+)*$";
  semverPrereleaseIdentifier = "(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)";
  semverPattern = "^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)(-${semverPrereleaseIdentifier}([.]${semverPrereleaseIdentifier})*)?([+][0-9A-Za-z-]+([.][0-9A-Za-z-]+)*)?$";
  colorPattern = "^#[0-9A-Fa-f]{6}$";

  validateOptionalString = value: field:
    if value ? ${field} then expectString "manifest.${field}" value.${field} else null;

  validateOptionalHttpsUrl = value: field:
    if value ? ${field} then
      expect
        (isString value.${field}
          && match "^https://[^/?#[:space:]][^[:space:]]*$" value.${field} != null)
        "manifest.${field} must be an absolute https:// URL"
        value.${field}
    else null;

  validateAuthor = manifest:
    if !(manifest ? author) then null else
    let
      author = rejectUnknown "manifest.author" [ "name" "email" "url" ]
        (expectAttrs "manifest.author" manifest.author);
      checks = [
        (expectString "manifest.author.name" (author.name or null))
        (if author ? email then expectString "manifest.author.email" author.email else null)
        (if author ? url then
          expect
            (isString author.url
              && match "^https://[^/?#[:space:]][^[:space:]]*$" author.url != null)
            "manifest.author.url must be an absolute https:// URL"
            author.url
        else null)
      ];
    in
    builtins.deepSeq checks author;

  interfaceStringFields = [
    "displayName"
    "shortDescription"
    "longDescription"
    "developerName"
    "category"
  ];

  interfaceUrlFields = [
    "websiteURL"
    "privacyPolicyURL"
    "termsOfServiceURL"
  ];

  validateInterface = manifest:
    if !(manifest ? interface) then null else
    let
      interface = rejectUnknown "manifest.interface"
        (interfaceStringFields ++ interfaceUrlFields ++ [
          "capabilities"
          "defaultPrompt"
          "brandColor"
        ])
        (expectAttrs "manifest.interface" manifest.interface);
      defaultPrompts =
        if interface ? defaultPrompt then
          let prompts = expectStringList "manifest.interface.defaultPrompt" interface.defaultPrompt;
          in expect
            (length prompts <= 3 && builtins.all (prompt: stringLength prompt <= 128) prompts)
            "manifest.interface.defaultPrompt must contain at most 3 strings of at most 128 characters"
            prompts
        else null;
      checks =
        map (validateOptionalString interface) interfaceStringFields
        ++ map (validateOptionalHttpsUrl interface) interfaceUrlFields
        ++ [
          (if interface ? capabilities then
            expectStringList "manifest.interface.capabilities" interface.capabilities
          else null)
          defaultPrompts
          (if interface ? brandColor then
            expect
              (isString interface.brandColor && match colorPattern interface.brandColor != null)
              "manifest.interface.brandColor must use #RRGGBB"
              interface.brandColor
          else null)
        ];
    in
    builtins.deepSeq checks interface;

  validateManifest = value:
    let
      rawManifest = expectAttrs "manifest" value;
      componentFields = builtins.filter
        (field: rawManifest ? ${field})
        [ "skills" "apps" "mcpServers" "hooks" ];
      skillsOnlyManifest = expect
        (componentFields == [ ])
        "manifest component fields are owned by the skills-only exporter or unsupported: ${builtins.concatStringsSep ", " componentFields}"
        rawManifest;
      manifest = rejectUnknown "manifest" [
        "name"
        "version"
        "description"
        "author"
        "homepage"
        "repository"
        "license"
        "keywords"
        "interface"
      ] skillsOnlyManifest;
      pluginName = expectString "manifest.name" (manifest.name or null);
      version = expectString "manifest.version" (manifest.version or null);
      description = expectString "manifest.description" (manifest.description or null);
      checks = [
        (expect
          (stringLength pluginName <= 64 && match pluginNamePattern pluginName != null)
          "manifest.name must be 1-64 characters of lowercase letters, numbers, and single hyphens"
          pluginName)
        (expect
          (match semverPattern version != null)
          "manifest.version must be strict semantic versioning"
          version)
        description
        (validateAuthor manifest)
        (validateInterface manifest)
        (validateOptionalString manifest "homepage")
        (validateOptionalString manifest "repository")
        (validateOptionalString manifest "license")
        (if manifest ? keywords then expectStringList "manifest.keywords" manifest.keywords else null)
      ];
    in
    builtins.deepSeq checks manifest;

  validateSkillName = name:
    expect
      (stringLength name <= 64 && match pluginNamePattern name != null)
      "skill output name '${name}' must be 1-64 characters of lowercase letters, numbers, and single hyphens"
      name;

  validateSkill = name: value:
    let
      skill = expectAttrs "skill '${name}'" value;
      packages = skill.packages or [ ];
      rawSourceRelPath = sourceRelPathFor skill;
      sourceRelPath = assertSafeRelPath "plugin skill ${name} source path"
        (expect
          (isString rawSourceRelPath)
          "skill '${name}'.sourceRelPath must be a string"
          rawSourceRelPath);
      sourceRoot =
        if skill ? sourceRoot || skill ? absPath then sourceRootFor skill else null;
      checks = [
        (validateSkillName name)
        (expect
          (skill ? sourceRoot || skill ? absPath)
          "skill '${name}' must be a selectSkills entry with sourceRoot or absPath"
          true)
        (expect
          (isPath sourceRoot || isString sourceRoot)
          "skill '${name}' sourceRoot must be a path or string"
          true)
        (expect
          (isList packages && length packages == 0)
          "skill '${name}'.packages must be an empty list because the portable skills-only exporter does not support packages"
          true)
        (expect
          (builtins.typeOf (skill.transform or null) == "null")
          "skill '${name}' uses transform, which the portable skills-only exporter does not support"
          true)
        sourceRelPath
      ];
    in
    builtins.deepSeq checks { inherit sourceRelPath sourceRoot; };

  validateSkills = value:
    let
      skills = expectAttrs "skills" value;
      names = attrNames skills;
      normalized = map
        (name: {
          inherit name;
          value = validateSkill name skills.${name};
        })
        names;
    in
    expect (names != [ ]) "skills must contain at least one selected skill"
      (builtins.deepSeq normalized (lib.listToAttrs normalized));

  mkAgentPlugin =
    { pkgs
    , manifest
    , skills
    , name ?
        if isAttrs manifest && manifest ? name && isString manifest.name
        then "agent-plugin-${manifest.name}"
        else "agent-plugin-invalid"
    }:
    let
      checkedManifest = validateManifest manifest;
      checkedSkills = validateSkills skills;
      skillNames = attrNames checkedSkills;
      skillList = map
        (skillName: checkedSkills.${skillName} // { outputName = skillName; })
        skillNames;

      uniqueSourceRoots = unique (map sourceRootFor skillList);
      dumpedRoots = map
        (root: builtins.path {
          path = root;
          name = "agent-skills-plugin-source";
        })
        uniqueSourceRoots;
      storePathFor = skill:
        let
          index = lib.lists.findFirstIndex
            (root: root == sourceRootFor skill)
            null
            uniqueSourceRoots;
        in
        if index == null then
          fail "internal error: source root not memoized"
        else
          builtins.elemAt dumpedRoots index;

      finalManifest = checkedManifest // { skills = "./skills/"; };
      manifestFile = pkgs.writeText "${checkedManifest.name}-plugin.json"
        (builtins.toJSON finalManifest);
      validatorPython = pkgs.python3.withPackages (pythonPackages: [ pythonPackages.pyyaml ]);
      validator = builtins.path {
        path = ../scripts/validate-agent-plugin.py;
        name = "validate-agent-plugin.py";
      };

      materializeCommands = concatMapStringsSep "\n"
        (skill:
          let
            sourceRoot = storePathFor skill;
            skillPath = appendRelPath sourceRoot skill.sourceRelPath;
          in
          ''
            ${validatorPython}/bin/python3 ${lib.escapeShellArg validator} source \
              --root ${lib.escapeShellArg sourceRoot} \
              --skill ${lib.escapeShellArg skillPath} \
              --name ${lib.escapeShellArg skill.outputName}
            mkdir -p "$out/skills/${skill.outputName}"
            ${pkgs.rsync}/bin/rsync -aL -- ${lib.escapeShellArg "${skillPath}/"} "$out/skills/${skill.outputName}/"
          '')
        skillList;
    in
    builtins.deepSeq [ checkedManifest checkedSkills ] (
      pkgs.runCommand name { preferLocalBuild = true; } ''
        mkdir -p "$out/.codex-plugin" "$out/skills"
        cp ${lib.escapeShellArg manifestFile} "$out/.codex-plugin/plugin.json"
        ${materializeCommands}
        ${validatorPython}/bin/python3 ${lib.escapeShellArg validator} plugin "$out"
      ''
    );
in
{
  inherit mkAgentPlugin;
}

{ lib }:

let
  inherit (builtins)
    attrNames
    filter
    fromJSON
    isAttrs
    isBool
    isInt
    isString
    match
    pathExists
    readDir
    readFile
    stringLength
    substring
    ;

  assertOnlyKeys = context: allowed: value:
    let
      unknown = filter (name: !(builtins.elem name allowed)) (attrNames value);
    in
    if unknown == [ ] then
      value
    else
      throw "agent-skills: ${context} has unknown fields: ${lib.concatStringsSep ", " unknown}";

  requireNonEmptyString = context: value:
    if isString value && value != "" then
      value
    else
      throw "agent-skills: ${context} must be a non-empty string";

  optionalString = context: value:
    if value == null || (isString value && value != "") then
      value
    else
      throw "agent-skills: ${context} must be null or a non-empty string";

  validateGitOptions = context: pin:
    let
      branch = optionalString "${context}.branch" (pin.branch or null);
      at = optionalString "${context}.at" (pin.at or null);
      versionUpperBound = optionalString "${context}.versionUpperBound" (pin.versionUpperBound or null);
      releasePrefix = optionalString "${context}.releasePrefix" (pin.releasePrefix or null);
      preReleases = pin.preReleases or false;
      submodules = pin.submodules or false;
    in
    if !isBool preReleases then
      throw "agent-skills: ${context}.preReleases must be a boolean"
    else if !isBool submodules then
      throw "agent-skills: ${context}.submodules must be a boolean"
    else if branch != null && preReleases then
      throw "agent-skills: ${context}.preReleases cannot be used with branch"
    else if branch != null && versionUpperBound != null then
      throw "agent-skills: ${context}.versionUpperBound cannot be used with branch"
    else if at != null && versionUpperBound != null then
      throw "agent-skills: ${context}.versionUpperBound cannot be used with at"
    else
      {
        inherit at branch preReleases releasePrefix submodules versionUpperBound;
      };

  validatePin = name: value:
    let
      context = "source manifest ${name}.pin";
      pin =
        if isAttrs value then
          value
        else
          throw "agent-skills: ${context} must be an attribute set";
      type = requireNonEmptyString "${context}.type" (pin.type or null);
      gitOptions = validateGitOptions context pin;
    in
    if type == "git" then
      let
        checked = assertOnlyKeys context [
          "at"
          "branch"
          "forge"
          "preReleases"
          "releasePrefix"
          "submodules"
          "type"
          "url"
          "versionUpperBound"
        ]
          pin;
        forge = checked.forge or "auto";
      in
      if !(builtins.elem forge [ "auto" "none" "github" "gitlab" "forgejo" ]) then
        throw "agent-skills: ${context}.forge must be one of auto, none, github, gitlab, or forgejo"
      else
        gitOptions
        // {
          inherit forge type;
          url = requireNonEmptyString "${context}.url" (checked.url or null);
        }
    else if type == "github" then
      let
        checked = assertOnlyKeys context [
          "at"
          "branch"
          "owner"
          "preReleases"
          "releasePrefix"
          "repo"
          "submodules"
          "type"
          "versionUpperBound"
        ]
          pin;
      in
      gitOptions
      // {
        inherit type;
        owner = requireNonEmptyString "${context}.owner" (checked.owner or null);
        repo = requireNonEmptyString "${context}.repo" (checked.repo or null);
      }
    else if type == "tarball" then
      let
        checked = assertOnlyKeys context [ "mutable" "type" "url" ] pin;
        mutable = checked.mutable or false;
      in
      if !isBool mutable then
        throw "agent-skills: ${context}.mutable must be a boolean"
      else
        {
          inherit mutable type;
          url = requireNonEmptyString "${context}.url" (checked.url or null);
        }
    else
      throw "agent-skills: ${context}.type '${type}' is unsupported (expected git, github, or tarball)";

  validateFilter = name: value:
    let
      context = "source manifest ${name}.filter";
      filterValue =
        if isAttrs value then
          assertOnlyKeys context [ "maxDepth" "nameRegex" ] value
        else
          throw "agent-skills: ${context} must be an attribute set";
      maxDepth = filterValue.maxDepth or null;
      nameRegex = optionalString "${context}.nameRegex" (filterValue.nameRegex or null);
    in
    if maxDepth != null && (!isInt maxDepth || maxDepth < 0) then
      throw "agent-skills: ${context}.maxDepth must be null or a non-negative integer"
    else
      { inherit maxDepth nameRegex; };

  validateManifest = name: value:
    let
      context = "source manifest ${name}";
      manifest =
        if isAttrs value then
          assertOnlyKeys context [ "filter" "idPrefix" "pin" "subdir" ] value
        else
          throw "agent-skills: ${context} must evaluate to an attribute set";
      subdir = manifest.subdir or ".";
      idPrefix = optionalString "${context}.idPrefix" (manifest.idPrefix or null);
      filterValue = validateFilter name (manifest.filter or { });
      unsafeSubdir =
        !isString subdir
        || lib.hasPrefix "/" subdir
        || subdir == ".."
        || lib.hasPrefix "../" subdir
        || lib.hasInfix "/../" subdir
        || lib.hasSuffix "/.." subdir;
    in
    if !(manifest ? pin) then
      throw "agent-skills: ${context} must define pin"
    else if unsafeSubdir then
      throw "agent-skills: ${context}.subdir must be relative and must not traverse outside the source root"
    else
      {
        filter = filterValue;
        inherit idPrefix subdir;
        pin = validatePin name manifest.pin;
      };

  manifestName = fileName:
    substring 0 (stringLength fileName - 4) fileName;

  loadSourceManifests = manifestsDir:
    let
      entries =
        if pathExists manifestsDir then
          readDir manifestsDir
        else
          throw "agent-skills: source manifest directory ${toString manifestsDir} does not exist";
      files = filter
        (fileName:
          lib.hasSuffix ".nix" fileName
          && builtins.elem entries.${fileName} [ "regular" "symlink" ])
        (attrNames entries);
      load = fileName:
        let
          name = manifestName fileName;
          validName = match "[A-Za-z0-9][A-Za-z0-9._-]*" name != null;
        in
        if !validName then
          throw "agent-skills: source manifest filename '${fileName}' must match [A-Za-z0-9][A-Za-z0-9._-]*.nix"
        else
          {
            inherit name;
            value = validateManifest name (import (manifestsDir + "/${fileName}"));
          };
    in
    builtins.listToAttrs (map load files);

  gitRepositoryUrl = name: repository:
    let
      context = "source lock pin ${name}.repository";
      type = repository.type or null;
    in
    if type == "Git" then
      requireNonEmptyString "${context}.url" (repository.url or null)
    else if type == "GitHub" then
      "https://github.com/${requireNonEmptyString "${context}.owner" (repository.owner or null)}/${requireNonEmptyString "${context}.repo" (repository.repo or null)}.git"
    else if type == "GitLab" then
      "${requireNonEmptyString "${context}.server" (repository.server or null)}/${requireNonEmptyString "${context}.repo_path" (repository.repo_path or null)}.git"
    else if type == "Forgejo" then
      "${requireNonEmptyString "${context}.server" (repository.server or null)}/${requireNonEmptyString "${context}.owner" (repository.owner or null)}/${requireNonEmptyString "${context}.repo" (repository.repo or null)}.git"
    else
      throw "agent-skills: ${context}.type '${toString type}' is unsupported";

  npinsPinFetchPlan = name: pin:
    let
      context = "source lock pin ${name}";
      type = pin.type or null;
      hash = requireNonEmptyString "${context}.hash" (pin.hash or null);
    in
    if type == "Git" || type == "GitRelease" then
      let
        revision = requireNonEmptyString "${context}.revision" (pin.revision or null);
        submodules = pin.submodules or false;
        url = pin.url or null;
      in
      if !isBool submodules then
        throw "agent-skills: ${context}.submodules must be a boolean"
      else if url != null && !submodules then
        {
          fetcher = "tarball";
          args = {
            inherit url;
            sha256 = hash;
          };
        }
      else
        {
          fetcher = "git";
          args = {
            url = gitRepositoryUrl name (pin.repository or { });
            rev = revision;
            narHash = hash;
            inherit submodules;
          };
        }
    else if (type == "Url" || type == "MutableUrl") && (pin.unpack or false) then
      {
        fetcher = "tarball";
        args = {
          url = requireNonEmptyString "${context}.url" (pin.url or null);
          sha256 = hash;
        };
      }
    else
      throw "agent-skills: ${context}.type '${toString type}' is not a supported directory source";

  fetchNpinsPin = name: pin:
    let
      plan = npinsPinFetchPlan name pin;
    in
    if plan.fetcher == "tarball" then
      builtins.fetchTarball plan.args
    else if plan.fetcher == "git" then
      (builtins.fetchGit plan.args).outPath
    else
      throw "agent-skills: internal error: unsupported source fetcher ${plan.fetcher}";

  sourcesFromLock =
    { manifestsDir
    , lockFile
    , fetchPin ? fetchNpinsPin
    ,
    }:
    let
      manifests = loadSourceManifests manifestsDir;
      lock =
        if pathExists lockFile then
          fromJSON (readFile lockFile)
        else
          throw "agent-skills: source lock file ${toString lockFile} does not exist; run skills-sources-lock";
      checkedLock =
        if !isAttrs lock then
          throw "agent-skills: source lock must contain a JSON object"
        else
          assertOnlyKeys "source lock" [ "manifests" "npins" "schemaVersion" ] lock;
      lockedManifests =
        if checkedLock.schemaVersion or null != 1 then
          throw "agent-skills: unsupported source lock schema version ${toString (checkedLock.schemaVersion or null)} (expected 1)"
        else if !isAttrs (checkedLock.manifests or null) then
          throw "agent-skills: source lock manifests must be an attribute set"
        else
          checkedLock.manifests;
      npinsLock =
        if lockedManifests != manifests then
          throw "agent-skills: source manifests differ from the lock; run skills-sources-lock"
        else if !isAttrs (checkedLock.npins or null) then
          throw "agent-skills: source lock npins value must be an attribute set"
        else
          assertOnlyKeys "source lock npins value" [ "pins" "version" ] checkedLock.npins;
      pins =
        if npinsLock.version or null != 8 then
          throw "agent-skills: unsupported npins source lock version ${toString (npinsLock.version or null)} (expected 8)"
        else if !isAttrs (npinsLock.pins or null) then
          throw "agent-skills: source lock pins must be an attribute set"
        else
          npinsLock.pins;
      manifestNames = attrNames manifests;
      pinNames = attrNames pins;
      namesMatch = manifestNames == pinNames;
    in
    if !namesMatch then
      throw "agent-skills: source manifests and lock pins differ (manifests: ${lib.concatStringsSep ", " manifestNames}; lock: ${lib.concatStringsSep ", " pinNames}); run skills-sources-lock"
    else
      builtins.mapAttrs
        (name: manifest: {
          path = fetchPin name pins.${name};
          inherit (manifest) filter idPrefix subdir;
        })
        manifests;

  mkSourceLockProgram =
    { pkgs
    , manifestsDir ? "registry/sources"
    , lockFile ? "registry/sources.lock.json"
    , npins ? pkgs.npins
    ,
    }:
    pkgs.writeShellApplication {
      name = "skills-sources-lock";
      runtimeInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.jq
        pkgs.nix
        npins
      ];
      text = ''
        export AGENT_SKILLS_SOURCE_NORMALIZER=${lib.escapeShellArg (toString ./eval-source-manifests.nix)}
        export AGENT_SKILLS_NIXPKGS_LIB=${lib.escapeShellArg (toString (pkgs.path + "/lib"))}
        export AGENT_SKILLS_SOURCE_REGISTRY_LIB=${lib.escapeShellArg (toString ./source-registry.nix)}
        exec ${pkgs.bash}/bin/bash ${../scripts/source-lock.sh} \
          --manifest-dir ${lib.escapeShellArg (toString manifestsDir)} \
          --lock-file ${lib.escapeShellArg (toString lockFile)} \
          "$@"
      '';
    };
in
{
  inherit loadSourceManifests mkSourceLockProgram sourcesFromLock;
  __internal = { inherit npinsPinFetchPlan; };
}

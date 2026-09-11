{ lib }:

let
  fail = message: throw "agent-skills: ${message}";

  assertOnlyKeys = context: allowed: value:
    if !builtins.isAttrs value then
      fail "${context} must be an attribute set"
    else
      let unknown = builtins.filter (name: !(builtins.elem name allowed)) (builtins.attrNames value);
      in
      if unknown != [ ] then
        fail "${context} has unknown fields: ${lib.concatStringsSep ", " unknown}"
      else value;

  optionalString = context: value:
    if value == null || (builtins.isString value && value != "") then value
    else fail "${context} must be null or a non-empty string";

  assertSafeRelPath = context: value:
    if !builtins.isString value then
      fail "${context} must be a string"
    else if lib.hasPrefix "/" value || builtins.elem ".." (lib.splitString "/" value) then
      fail "${context} '${value}' must be relative and must not traverse outside the source root"
    else value;

  assertSkillId = value:
    if !builtins.isString value || value == ""
      || lib.hasInfix ".." value
      || builtins.any (part: part == "" || part == ".") (lib.splitString "/" value)
    then fail "invalid skill id (must be a non-empty string with non-empty path components, without '.' or '..')"
    else value;

  # Discovery settings are identical for direct sources and registry manifests.
  normalizeDiscoveryConfig = context: value:
    let
      cfg = assertOnlyKeys context [ "subdir" "idPrefix" "filter" ] value;
      rel = assertSafeRelPath "${context}.subdir" (cfg.subdir or ".");
      prefix = optionalString "${context}.idPrefix" (cfg.idPrefix or null);
      filter = assertOnlyKeys "${context}.filter" [ "maxDepth" "nameRegex" ] (cfg.filter or { });
      depth = filter.maxDepth or null;
      normalized = {
        subdir = if rel == "" then "." else rel;
        idPrefix = if prefix == null then null else assertSkillId prefix;
        filter = {
          maxDepth =
            if depth == null || (builtins.isInt depth && depth >= 0) then depth
            else fail "${context}.filter.maxDepth must be null or a non-negative integer";
          nameRegex = optionalString "${context}.filter.nameRegex" (filter.nameRegex or null);
        };
      };
    in
    builtins.deepSeq normalized normalized;

  normalizeSourceConfig = name: value:
    let
      context = "source ${name}";
      cfg = assertOnlyKeys context [ "input" "path" "subdir" "idPrefix" "filter" ] value;
      rawPath = cfg.path or null;
      path = if builtins.isAttrs rawPath && rawPath ? outPath then rawPath.outPath else rawPath;
      input = optionalString "${context}.input" (cfg.input or null);
      discovery = normalizeDiscoveryConfig context (builtins.removeAttrs cfg [ "input" "path" ]);
      normalized = discovery // { inherit input path; };
    in
    if path != null && !(builtins.isPath path || (builtins.isString path && lib.hasPrefix "/" path)) then
      fail "${context}.path must be an absolute path or an input with outPath"
    else if path == null && input == null then
      fail "${context} must set either `path` or `input`"
    else builtins.deepSeq normalized normalized;

  normalizeSources = value:
    if !builtins.isAttrs value then fail "sources must be an attribute set"
    else
      let normalized = builtins.mapAttrs normalizeSourceConfig value;
      in builtins.deepSeq normalized normalized;
in
{
  inherit assertOnlyKeys assertSafeRelPath assertSkillId
    normalizeDiscoveryConfig normalizeSourceConfig normalizeSources;
}

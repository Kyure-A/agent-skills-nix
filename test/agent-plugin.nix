# Contract tests for self-contained, skills-only Codex Agent Plugin exports.
{ pkgs, agentLib }:

let
  fixtureRoot = ./fixtures/agent-plugin;
  validatorPython = pkgs.python3.withPackages (pythonPackages: [ pythonPackages.pyyaml ]);
  validator = builtins.path {
    path = ../scripts/validate-agent-plugin.py;
    name = "validate-agent-plugin.py";
  };

  selectedEntryFor = sourcePath: skillPath:
    let
      sources = {
        fixture = {
          path = sourcePath;
        };
      };
      selection = agentLib.selectSkills {
        catalog = { };
        allowlist = [ ];
        inherit sources;
        skills = {
          selected = {
            from = "fixture";
            path = skillPath;
          };
        };
      };
    in
    selection.selected;

  validSources = {
    fixture = {
      path = fixtureRoot + "/valid";
    };
  };
  validCatalog = agentLib.discoverCatalog validSources;
  validSelection = agentLib.selectSkills {
    catalog = validCatalog;
    allowlist = [ "hello" ];
    skills = { };
    sources = validSources;
  };
  # An allowlisted discovery record intentionally lacks the explicit
  # selection-only `packages` and `transform` attributes.
  validEntry = validSelection.hello;

  minimalPlugin = agentLib.mkAgentPlugin {
    inherit pkgs;
    manifest = {
      name = "portable-tools";
      version = "1.0.0";
      description = "A minimal, portable skills-only plugin fixture.";
    };
    skills = {
      hello = validEntry;
    };
  };

  metadataPlugin = agentLib.mkAgentPlugin {
    inherit pkgs;
    manifest = {
      name = "portable-tools-metadata";
      version = "1.0.0";
      description = "Exercises optional Codex Agent Plugin metadata.";
      author = {
        name = "Agent Skills Nix";
        email = "maintainers@example.invalid";
        url = "https://example.invalid/agent-skills-nix";
      };
      homepage = "https://example.invalid/agent-skills-nix";
      repository = "https://example.invalid/agent-skills-nix.git";
      license = "MIT";
      keywords = [ "nix" "agent-skills" ];
      interface = {
        displayName = "Portable Tools";
        shortDescription = "Portable Agent Skills built with Nix";
        longDescription = "Exports selected Agent Skills as a self-contained Codex Agent Plugin.";
        developerName = "Agent Skills Nix";
        category = "Engineering";
        capabilities = [ "Read" ];
        websiteURL = "https://example.invalid/agent-skills-nix";
        defaultPrompt = [ "Run the portable hello skill" ];
        brandColor = "#123456";
      };
    };
    skills = {
      hello = validEntry;
    };
  };

  tryPlugin = manifest: skills:
    builtins.tryEval (builtins.deepSeq
      (agentLib.mkAgentPlugin {
        inherit pkgs manifest skills;
      })
      true);

  invalidPluginName = tryPlugin
    {
      name = "Invalid Name";
      version = "1.0.0";
      description = "Invalid plugin name fixture.";
    }
    {
      hello = validEntry;
    };

  invalidSkillName = tryPlugin
    {
      name = "portable-tools";
      version = "1.0.0";
      description = "Invalid portable skill name fixture.";
    }
    {
      "Hello World" = validEntry;
    };

  packagesNotPortable = tryPlugin
    {
      name = "portable-tools";
      version = "1.0.0";
      description = "Package dependency rejection fixture.";
    }
    {
      hello = validEntry // {
        packages = [ pkgs.jq ];
      };
    };

  transformNotPortable = tryPlugin
    {
      name = "portable-tools";
      version = "1.0.0";
      description = "Transform rejection fixture.";
    }
    {
      hello = validEntry // {
        transform = _: "not portable";
      };
    };

  callerOwnedSkills = tryPlugin
    {
      name = "portable-tools";
      version = "1.0.0";
      description = "Caller-owned component path rejection fixture.";
      skills = "./other-skills/";
    }
    {
      hello = validEntry;
    };

  callerOwnedApps = tryPlugin
    {
      name = "portable-tools";
      version = "1.0.0";
      description = "Caller-owned app component rejection fixture.";
      apps = "./.app.json";
    }
    {
      hello = validEntry;
    };

  callerOwnedMcpServers = tryPlugin
    {
      name = "portable-tools";
      version = "1.0.0";
      description = "Caller-owned MCP component rejection fixture.";
      mcpServers = "./.mcp.json";
    }
    {
      hello = validEntry;
    };

  callerOwnedHooks = tryPlugin
    {
      name = "portable-tools";
      version = "1.0.0";
      description = "Caller-owned hooks component rejection fixture.";
      hooks = "./hooks.json";
    }
    {
      hello = validEntry;
    };

  invalidFrontmatterPlugin = agentLib.mkAgentPlugin {
    inherit pkgs;
    manifest = {
      name = "invalid-frontmatter";
      version = "1.0.0";
      description = "Must fail because the skill name does not match its output directory.";
    };
    skills = {
      hello = selectedEntryFor (fixtureRoot + "/invalid-frontmatter") ".";
    };
  };
  invalidFrontmatterFailure = pkgs.testers.testBuildFailure invalidFrontmatterPlugin;

  escapingSymlinkPlugin = agentLib.mkAgentPlugin {
    inherit pkgs;
    manifest = {
      name = "escaping-symlink";
      version = "1.0.0";
      description = "Must fail because the skill contains a source-root escape.";
    };
    skills = {
      hello = selectedEntryFor (fixtureRoot + "/escaping") "hello";
    };
  };
  escapingSymlinkFailure = pkgs.testers.testBuildFailure escapingSymlinkPlugin;
in
pkgs.runCommand "agent-skills-agent-plugin-test"
{
  nativeBuildInputs = [ pkgs.findutils pkgs.jq validatorPython ];
}
  ''
    set -euo pipefail

    plugin=${minimalPlugin}
    manifest="$plugin/.codex-plugin/plugin.json"
    skill="$plugin/skills/hello"

    test -f "$manifest"
    test ! -e "$plugin/plugin.json"
    test -d "$skill"
    test -f "$skill/SKILL.md"
    test "$(jq -r .name "$manifest")" = portable-tools
    test "$(jq -r .version "$manifest")" = 1.0.0
    test "$(jq -r .skills "$manifest")" = ./skills/
    test "$(jq -r 'keys | sort | join(",")' "$manifest")" = description,name,skills,version

    test -f "$skill/.fixture-config"
    grep -Fx 'preserve-dotfiles=true' "$skill/.fixture-config"
    test -x "$skill/scripts/greet.sh"
    ${pkgs.bash}/bin/bash "$skill/scripts/greet.sh" \
      | grep -Fx 'hello from the portable plugin fixture'

    # The source-root-relative symlink is useful input structure, but the plugin
    # output must be independently installable and contain no symlinks.
    test -d "$skill/shared"
    test ! -L "$skill/shared"
    grep -Fx 'shared data materialized from a source-root-relative symlink' \
      "$skill/shared/message.txt"
    if find "$plugin" -type l -print | grep -q .; then
      echo "Agent Plugin output must not contain symlinks" >&2
      find "$plugin" -type l -print >&2
      exit 1
    fi

    test "$(find "$plugin/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = 1

    metadata_manifest=${metadataPlugin}/.codex-plugin/plugin.json
    test "$(jq -r '.author.name' "$metadata_manifest")" = 'Agent Skills Nix'
    test "$(jq -r '.keywords[1]' "$metadata_manifest")" = agent-skills
    test "$(jq -r '.interface.displayName' "$metadata_manifest")" = 'Portable Tools'
    test "$(jq -r '.skills' "$metadata_manifest")" = ./skills/

    ${if invalidPluginName.success then ''
      echo "Invalid plugin names must be rejected during evaluation" >&2
      exit 1
    '' else ''
      echo "Invalid plugin name rejected"
    ''}

    ${if invalidSkillName.success then ''
      echo "Invalid portable skill names must be rejected during evaluation" >&2
      exit 1
    '' else ''
      echo "Invalid portable skill name rejected"
    ''}

    ${if packagesNotPortable.success then ''
      echo "Package-bearing selections are not portable in the skills-only v1 exporter" >&2
      exit 1
    '' else ''
      echo "Package-bearing selection rejected"
    ''}

    ${if transformNotPortable.success then ''
      echo "Transformed selections are not portable in the skills-only v1 exporter" >&2
      exit 1
    '' else ''
      echo "Transformed selection rejected"
    ''}

    ${if callerOwnedSkills.success then ''
      echo "The exporter must own the manifest skills component path" >&2
      exit 1
    '' else ''
      echo "Caller-owned component path rejected"
    ''}

    ${if callerOwnedApps.success || callerOwnedMcpServers.success || callerOwnedHooks.success then ''
      echo "The skills-only exporter must reject non-skill component fields" >&2
      exit 1
    '' else ''
      echo "Non-skill component fields rejected"
    ''}

    test -s ${invalidFrontmatterFailure}/testBuildFailure.log
    test -s ${escapingSymlinkFailure}/testBuildFailure.log
    grep -F 'frontmatter.name must match its output directory' \
      ${invalidFrontmatterFailure}/testBuildFailure.log
    grep -F 'contains a dangling or cyclic symlink' \
      ${escapingSymlinkFailure}/testBuildFailure.log

    # builtins.path isolates the declared source root, so a relative escape
    # becomes dangling in the plugin build above. Exercise the explicit
    # out-of-root containment branch against an existing sibling here.
    escape_tree="$TMPDIR/agent-plugin-validator-escape"
    mkdir -p "$escape_tree/root/hello" "$escape_tree/outside"
    touch "$escape_tree/root/hello/SKILL.md" "$escape_tree/outside/data.txt"
    ln -s ../../outside "$escape_tree/root/hello/outside"
    if python3 ${validator} source \
      --root "$escape_tree/root" \
      --skill "$escape_tree/root/hello" \
      --name hello >"$escape_tree/validator.log" 2>&1; then
      echo "Existing source-root escape must be rejected" >&2
      exit 1
    fi
    grep -F 'resolves outside its declared source root' "$escape_tree/validator.log"

    mkdir -p "$out"
    touch "$out/ok"
  ''

{
  description = "skills catalog flake for project child pattern";

  inputs = {
    agent-skills.url = "github:Kyure-A/agent-skills-nix";
    anthropic-skills = {
      url = "github:anthropics/skills";
      flake = false;
    };
  };

  outputs = { self, agent-skills, anthropic-skills, ... }:
    {
      homeManagerModules.default = {
        imports = [
          agent-skills.homeManagerModules.default
          (import ./home-manager.nix { inherit anthropic-skills; })
        ];
      };
    };
}

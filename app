// HireFlow Main Application Bootstrap
document.addEventListener('DOMContentLoaded', async () => {
  console.log("HireFlow Agent App initializing...");

  // Initialize Navbar
  Navbar.init();
  CandidatesView.init();

  // Load initial data
  try {
    const roles = await API.getRoles();
    if (roles.length > 0) {
      State.setRoles(roles);
      const firstRole = roles[0];
      State.setCurrentRole(firstRole);
      const candidates = await API.getRoleCandidates(firstRole.id);
      State.setCandidates(candidates);
    } else {
      // If no roles exist yet, prompt to seed demo showcase
      console.log("No roles found, prompting or seeding demo...");
      const res = await API.seedDemo();
      const seededRoles = await API.getRoles();
      State.setRoles(seededRoles);
      if (seededRoles.length > 0) {
        State.setCurrentRole(seededRoles[0]);
        const candidates = await API.getRoleCandidates(seededRoles[0].id);
        State.setCandidates(candidates);
      }
    }
  } catch (err) {
    console.error("Initialization error:", err);
  }

  // Global modal close on backdrop click
  document.querySelectorAll('.modal-backdrop').forEach(modal => {
    modal.addEventListener('click', (e) => {
      if (e.target === modal) {
        modal.classList.add('hidden');
      }
    });
  });

  // Attach modal form submissions
  const roleForm = document.getElementById('new-role-form');
  if (roleForm) {
    roleForm.addEventListener('submit', (e) => RolesView.handleRoleSubmit(e));
  }

  const settingsForm = document.getElementById('settings-form');
  if (settingsForm) {
    settingsForm.addEventListener('submit', (e) => SettingsModal.handleSave(e));
  }

  lucide.createIcons();
});

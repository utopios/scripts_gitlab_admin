# Owners (hors root) de tous les groupes et projets, avec origine du compte
Member.where(access_level: Gitlab::Access::OWNER).includes(:user, :source).find_each do |m|
  u = m.user
  next if u.nil? || u.username == "root" || u.bot?
  origine = u.ldap_user? ? "ldap" : "local"
  puts [u.username, origine, (u.external? ? "externe" : "interne"), m.source_type, m.source.full_path].join("  ")
end

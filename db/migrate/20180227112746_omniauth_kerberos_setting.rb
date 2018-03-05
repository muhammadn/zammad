class OmniauthKerberosSetting < ActiveRecord::Migration[5.1]
  def change
    # return if it's a new setup
    return if !Setting.find_by(name: 'system_init_done')
    Setting.create_if_not_exists(
      title: 'Authentication via %s',
      name: 'auth_kerberos',
      area: 'Security::ThirdPartyAuthentication',
      description: 'Enables user authentication via %s.',
      options: {
        form: [
          {
            display: '',
            null: true,
            name: 'auth_kerberos',
            tag: 'boolean',
            options: {
              true  => 'yes',
              false => 'no',
            },
          },
        ],
      },
      preferences: {
        controller: 'SettingsAreaSwitch',
        sub: ['auth_kerberos_credentials'],
        title_i18n: ['Kerberos'],
        description_i18n: ['Kerberos', 'MIT Kerberos', 'https://web.mit.edu/kerberos'],
        permission: ['admin.security'],
      },
      state: false,
      frontend: true
    )
    Setting.create_if_not_exists(
      title: 'Kerberos Credentials Stub',
      name: 'auth_kerberos_credentials',
      area: 'Security::ThirdPartyAuthentication::Kerberos',
      description: 'Enables user authentication via MIT Kerberos.',
      options: { form: [] },
      state: {},
      preferences: {
        permission: ['admin.security'],
      },
      frontend: false
    )
  end
end

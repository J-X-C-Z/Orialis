use std::{env, net::SocketAddr, path::PathBuf};

#[derive(Clone)]
pub(crate) struct Config {
    pub(crate) host: String,
    pub(crate) port: u16,
    pub(crate) environment: String,
    pub(crate) public_url: String,
    pub(crate) database_url: String,
    pub(crate) agent_device_token: Option<String>,
    pub(crate) agent_user_id: Option<String>,
    pub(crate) upload_dir: PathBuf,
}

impl Config {
    pub(crate) fn from_env() -> Result<Self, String> {
        let environment = env::var("ORIALIS_ENV").unwrap_or_else(|_| "development".into());
        validate_environment_security(&environment, development_device_auth_enabled())?;
        let port = env::var("ORIALIS_PORT")
            .unwrap_or_else(|_| "18443".into())
            .parse::<u16>()
            .map_err(|_| "ORIALIS_PORT must be a valid port number".to_string())?;
        Ok(Self {
            host: env::var("ORIALIS_HOST").unwrap_or_else(|_| "127.0.0.1".into()),
            port,
            environment,
            public_url: env::var("ORIALIS_PUBLIC_URL")
                .unwrap_or_else(|_| "https://orialis.jxcz.top".into()),
            database_url: env::var("ORIALIS_DATABASE_URL")
                .unwrap_or_else(|_| "sqlite://./orialis.db?mode=rwc".into()),
            agent_device_token: env::var("ORIALIS_AGENT_DEVICE_TOKEN")
                .ok()
                .filter(|token| !token.trim().is_empty()),
            agent_user_id: env::var("ORIALIS_AGENT_USER_ID")
                .ok()
                .map(|user_id| user_id.trim().to_owned())
                .filter(|user_id| !user_id.is_empty()),
            upload_dir: env::var("ORIALIS_UPLOAD_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|_| PathBuf::from("./uploads")),
        })
    }

    pub(crate) fn address(&self) -> Result<SocketAddr, String> {
        format!("{}:{}", self.host, self.port)
            .parse()
            .map_err(|_| "ORIALIS_HOST and ORIALIS_PORT do not form a valid socket address".into())
    }
}

pub(crate) fn development_device_auth_enabled() -> bool {
    matches!(
        env::var("ORIALIS_DEV_DEVICE_AUTH").as_deref(),
        Ok("1") | Ok("true") | Ok("TRUE") | Ok("yes") | Ok("YES")
    )
}

fn validate_environment_security(
    environment: &str,
    development_device_auth: bool,
) -> Result<(), String> {
    if environment.eq_ignore_ascii_case("production") && development_device_auth {
        return Err("ORIALIS_DEV_DEVICE_AUTH must be disabled in production".to_string());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn production_rejects_development_device_auth() {
        assert!(super::validate_environment_security("production", true).is_err());
        assert!(super::validate_environment_security("production", false).is_ok());
        assert!(super::validate_environment_security("development", true).is_ok());
    }
}

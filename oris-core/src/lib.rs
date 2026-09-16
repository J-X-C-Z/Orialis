use serde::Serialize;

pub const SERVICE_NAME: &str = "orialis";
pub const API_VERSION: &str = "v1";

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct ServiceMetadata {
    pub service: &'static str,
    pub api_version: &'static str,
    pub version: String,
    pub environment: String,
    pub public_url: String,
}

pub fn metadata(version: impl Into<String>, environment: impl Into<String>, public_url: impl Into<String>) -> ServiceMetadata {
    ServiceMetadata {
        service: SERVICE_NAME,
        api_version: API_VERSION,
        version: version.into(),
        environment: environment.into(),
        public_url: public_url.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn creates_oris_metadata() {
        let value = metadata("0.1.0", "development", "https://orialis.jxcz.top");
        assert_eq!(value.service, "orialis");
        assert_eq!(value.api_version, "v1");
        assert_eq!(value.public_url, "https://orialis.jxcz.top");
    }
}


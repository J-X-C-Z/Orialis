//! Bridges explicitly configured host integrations into the agent tool registry.
use crate::{
    domain_tools::{self, DomainClient},
    tool_runtime::{ToolExecutor, TurnContext},
};
use anyhow::Result;
use futures_util::future::BoxFuture;
use serde_json::Value;

pub struct OrialisDomainTools(pub DomainClient);
impl ToolExecutor for OrialisDomainTools {
    fn schemas(&self) -> Vec<Value> {
        domain_tools::schemas()
    }
    fn execute<'a>(
        &'a self,
        name: &'a str,
        arguments: Value,
        _context: &'a TurnContext,
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async move { Ok(self.0.execute(name, arguments).await) })
    }
}

/// Recheck the configured bearer owner at each domain-tool boundary. A server
/// restart or token remap cannot move an old private conversation into a new
/// account merely because the URL/device label stayed the same.
pub struct OwnerCheckedDomainTools {
    pub client: DomainClient,
    pub verifier: crate::account_scope::OwnerVerifier,
    pub expected_scope: String,
}
impl ToolExecutor for OwnerCheckedDomainTools {
    fn schemas(&self) -> Vec<Value> {
        domain_tools::schemas()
    }
    fn execute<'a>(
        &'a self,
        name: &'a str,
        args: Value,
        _context: &'a TurnContext,
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async move {
            let owner = self.verifier.verify().await?;
            anyhow::ensure!(
                owner.scope() == self.expected_scope,
                "domain account changed; private turn was not forwarded"
            );
            Ok(self.client.execute(name, args).await)
        })
    }
}

/// A host-only facade for an explicit Python callback allowlist. The same
/// configured executor instances retain scope, authorization and turn leases;
/// this is not registered as another top-level model dispatch tool.
pub struct ExecutorGroup(crate::tool_runtime::ToolRouter);
impl ExecutorGroup {
    pub fn new(executors: Vec<std::sync::Arc<dyn ToolExecutor>>) -> Result<Self> {
        Ok(Self(crate::tool_runtime::ToolRouter::new(executors)?))
    }
}
impl ToolExecutor for ExecutorGroup {
    fn schemas(&self) -> Vec<Value> {
        self.0.schemas().to_vec()
    }
    fn set_session_generation<'a>(
        &'a self,
        route: &'a str,
        generation: i64,
    ) -> BoxFuture<'a, Result<()>> {
        Box::pin(async move { self.0.set_session_generation(route, generation).await })
    }
    fn execute<'a>(
        &'a self,
        name: &'a str,
        arguments: Value,
        context: &'a TurnContext,
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async move { self.0.execute(name, arguments, context).await })
    }
    fn execute_at_generation<'a>(
        &'a self,
        name: &'a str,
        arguments: Value,
        context: &'a TurnContext,
        generation: i64,
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async move {
            self.0
                .execute_at_generation(name, arguments, context, generation)
                .await
        })
    }
}

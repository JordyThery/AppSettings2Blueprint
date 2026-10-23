import Foundation

/// Where a deployment stands, from the blueprint's `deploymentState.lastDeployment`
/// and the status report.
nonisolated struct DeploymentStatus: Hashable, Sendable {
    /// `PENDING`, `DEPLOYING`, `SUCCEEDED` or `FAILED`; nil until the new deployment shows up.
    var jobState: String?
    var jobStarted: String?
    /// `NOT_DEPLOYED`, `DEPLOYED` or `OUT_OF_DATE`.
    var blueprintState: DeploymentStateKind?
    var report: BlueprintStatusReport?
    var checkedAt: Date

    var isFinished: Bool { jobState == "SUCCEEDED" || jobState == "FAILED" }
    var didSucceed: Bool { jobState == "SUCCEEDED" }
}

/// Starts a deployment and follows it: POST deploy (retried on 429 only), then GET
/// the blueprint and its report until this deployment succeeds or fails.
nonisolated struct DeploymentMonitor: Sendable {
    let service: BlueprintService
    var interval: Duration = .seconds(4)
    /// 45 polls of 4 s: about three minutes.
    var maxPolls = 45
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    /// POST /blueprints/v1/blueprints/{id}/deploy. Fetches the blueprint first and
    /// returns the fresh deployment start time, so polling cannot mistake a
    /// deployment started since the caller's copy was loaded for the new one.
    func deploy(_ detail: BlueprintDetail) async throws -> String? {
        let latest = try await service.detail(id: detail.id)
        let previous = latest.overview.deploymentState?.lastDeploymentStarted
        try await service.deploy(id: detail.id)
        return previous
    }

    /// Polls until the deployment that replaced `previousStart` finishes, or
    /// `maxPolls` is reached. Every poll is reported through `update`.
    @discardableResult
    func watch(id: String, previousStart: String?, update: @Sendable (DeploymentStatus) async -> Void) async throws -> DeploymentStatus {
        var status = DeploymentStatus(checkedAt: Date())
        for poll in 1...max(maxPolls, 1) {
            try Task.checkCancellation()
            let detail = try await service.detail(id: id)
            let deployment = detail.overview.deploymentState
            let isNew = deployment?.lastDeploymentStarted != nil && deployment?.lastDeploymentStarted != previousStart
            status = DeploymentStatus(
                jobState: isNew ? deployment?.lastDeploymentState : nil,
                jobStarted: isNew ? deployment?.lastDeploymentStarted : nil,
                blueprintState: deployment?.state,
                report: try? await service.report(id: id),
                checkedAt: Date()
            )
            await update(status)
            if status.isFinished || poll == maxPolls { break }
            try await sleep(interval)
        }
        return status
    }
}

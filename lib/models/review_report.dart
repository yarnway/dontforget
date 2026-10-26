/// Provenance belongs to the returned report, never shared last-request state.
enum ReviewReportSource { model, local, localAfterFailure }

class ReviewReport {
  const ReviewReport(this.content, {required this.source});
  final String content;
  final ReviewReportSource source;
}

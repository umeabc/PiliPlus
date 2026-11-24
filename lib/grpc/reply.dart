import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:PiliPlus/grpc/bilibili/pagination.pb.dart';
import 'package:PiliPlus/grpc/grpc_req.dart';
import 'package:PiliPlus/grpc/url.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/services/dafeiyu/models.dart';
import 'package:PiliPlus/services/dafeiyu/service.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:fixnum/fixnum.dart';

abstract final class ReplyGrpc {
  static bool antiGoodsReply = Pref.antiGoodsReply;
  static var blockAtOnlyReply = Pref.blockAtOnlyReply;
  static var blockReplyAtCount = Pref.blockReplyAtCount;
  static RegExp replyRegExp = RegExp(
    Pref.banWordForReply,
    caseSensitive: false,
  );
  static bool enableFilter = replyRegExp.pattern.isNotEmpty;

  // static Future replyInfo({required int rpid}) {
  //   return _request(
  //     GrpcUrl.replyInfo,
  //     ReplyInfoReq(rpid: Int64(rpid)),
  //     ReplyInfoReply.fromBuffer,
  //     onSuccess: (response) => response.reply,
  //   );
  // }

  static bool _hasGoods(Url url) =>
      url.hasExtra() &&
      (url.extra.goodsCmControl == Int64.ONE ||
          url.extra.hasGoodsItemId() ||
          url.extra.hasGoodsPrefetchedCache());

  // ref BiliRoamingX
  @pragma('vm:prefer-inline')
  static bool _needRemoveGoodGrpc(ReplyInfo reply) {
    return (reply.content.urls.isNotEmpty &&
            reply.content.urls.values.any(_hasGoods)) ||
        reply.content.message.contains(Constants.goodsUrlPrefix);
  }

  static bool _blockAtOnlyReply(ReplyInfo reply) {
    if (!blockAtOnlyReply) return false;

    final content = reply.content;
    final atNameToMid = content.atNameToMid;
    if (atNameToMid.isEmpty) return false;
    if (content.emotes.isNotEmpty || content.pictures.isNotEmpty) return false;

    final message = content.message;
    final length = message.length;

    int i = 0;

    if (reply.root != reply.parent) {
      i = message.indexOf(':') + 1;
      if (i <= 0) return false;
    }

    var hasAt = false;
    while (i < length) {
      var c = message.codeUnitAt(i);

      if (c case 0x20 /* ` ` */ || 0x0A /* `\n` */ ) {
        i++;
        continue;
      }

      if (c != 0x40 /* `@` */ ) return false;

      i++;
      final nameStart = i;

      while (i < length) {
        c = message.codeUnitAt(i);
        if (c case 0x20 || 0x40 || 0x0A) {
          break;
        }
        i++;
      }

      if (i == nameStart) return false;
      final name = message.substring(nameStart, i);
      if (!atNameToMid.containsKey(name)) return false;

      hasAt = true;
    }

    return hasAt;
  }

  static bool _blockReplyAtCount(ReplyInfo reply) {
    return blockReplyAtCount != null &&
        reply.content.atNameToMid.length >= blockReplyAtCount!;
  }

  static bool needRemoveGrpc(ReplyInfo reply) {
    return GlobalData().blackMids.contains(reply.mid.toInt()) ||
        _blockReplyAtCount(reply) ||
        _blockAtOnlyReply(reply) ||
        (antiGoodsReply && _needRemoveGoodGrpc(reply)) ||
        (enableFilter && replyRegExp.hasMatch(reply.content.message));
  }

  static bool _dfyCurrent(DfySession session, int generation) =>
      session.accountId == DfyService.instance.accountId &&
      identical(
        session,
        DfyService.instance.peekSession(session.oid, session.type),
      ) &&
      session.generation == generation;

  static Future<LoadingState<MainListReply>> mainList({
    required int type,
    required int oid,
    Int64? rpid,
    required Mode mode,
    required String? offset,
  }) async {
    final dfy = DfyService.instance;
    if (offset == null) dfy.resetSubject(oid, type);
    final session = dfy.sessionFor(oid, type);
    final generation = session.generation;
    final seenOffsets = <String>{?offset};
    var next = offset;
    // Bound empty-page lookahead; never recurse indefinitely when all comments match.
    for (var page = 0; ; page++) {
      final res = await GrpcReq.request(
        GrpcUrl.mainList,
        MainListReq(
          oid: Int64(oid),
          type: Int64(type),
          rpid: rpid,
          mode: mode,
          pagination: next == null ? null : FeedPagination(offset: next),
        ),
        MainListReply.fromBuffer,
      );
      // A newer load owns this subject: return the raw payload unfiltered
      // rather than replacing the page with an error.
      if (!_dfyCurrent(session, generation)) return res;
      if (res case Success(:final response)) {
        dfy.filterMain(response, oid: oid, type: type);
        // Keep existing PiliPlus blacklist/goods/custom regex filters independent.
        if (response.hasUpTop()) {
          final topReply = response.upTop;
          if (needRemoveGrpc(topReply)) {
            response.clearUpTop();
          } else {
            topReply.replies.removeWhere(needRemoveGrpc);
          }
        }
        response.replies.removeWhere((item) {
          final hit = needRemoveGrpc(item);
          if (!hit) item.replies.removeWhere(needRemoveGrpc);
          return hit;
        });
        final newOffset = response.paginationReply.nextOffset;
        if (response.replies.isEmpty &&
            !response.hasUpTop() &&
            !response.cursor.isEnd &&
            newOffset.isNotEmpty &&
            seenOffsets.add(newOffset) &&
            page < 7) {
          next = newOffset;
          continue;
        }
      }
      return res;
    }
  }

  static Future<LoadingState<DetailListReply>> detailList({
    required int type,
    required int oid,
    required int root,
    required int rpid,
    required Mode mode,
    required String? offset,
    Map<Int64, ReplyInfo>? removed,
  }) async {
    final dfy = DfyService.instance;
    final session = dfy.sessionFor(oid, type);
    final generation = session.generation;
    final res = await GrpcReq.request(
      GrpcUrl.detailList,
      DetailListReq(
        oid: Int64(oid),
        type: Int64(type),
        root: Int64(root),
        rpid: Int64(rpid),
        scene: DetailListScene.REPLY,
        mode: mode,
        pagination: offset == null ? null : FeedPagination(offset: offset),
      ),
      DetailListReply.fromBuffer,
    );
    // A newer load owns this subject: return the raw payload unfiltered
    // rather than replacing the page with an error.
    if (!_dfyCurrent(session, generation)) return res;
    if (res case Success(:final response)) {
      final owner = response.subjectControl.upMid.toString();
      if (owner != '0') session.ownerMid = owner;
      // Detail payloads may be opened directly, without a main-list pin registry.
      final control = response.root.replyControl;
      if (control.isUpTop || control.isAdminTop || control.isVoteTop) {
        session.pinRoot(root.toString());
      }
      dfy.filterChildren(
        response.root.replies,
        oid: oid,
        type: type,
        rootId: root.toString(),
        removed: removed,
      );
      response.root.replies.removeWhere((item) {
        final hit = needRemoveGrpc(item);
        if (hit) removed?[item.id] = item;
        return hit;
      });
    }
    return res;
  }

  static Future<LoadingState<FoldListResp>> foldList({
    required int type,
    required int oid,
    required FeedPagination pagination,
  }) async {
    final dfy = DfyService.instance;
    final session = dfy.sessionFor(oid, type);
    final generation = session.generation;
    final res = await GrpcReq.request(
      GrpcUrl.foldList,
      FoldListReq(
        oid: Int64(oid),
        type: Int64(type),
        pagination: pagination,
      ),
      FoldListResp.fromBuffer,
    );
    // A newer load owns this subject: return the raw payload unfiltered
    // rather than replacing the page with an error.
    if (!_dfyCurrent(session, generation)) return res;
    if (res case Success(:final response)) {
      final roots = response.replies
          .where((r) => r.root == Int64.ZERO)
          .toList();
      final main = MainListReply(replies: roots);
      dfy.filterMain(main, oid: oid, type: type);
      final keptRoots = main.replies.map((r) => r.id).toSet();
      response.replies.removeWhere(
        (r) => r.root == Int64.ZERO && !keptRoots.contains(r.id),
      );
      // Fold responses can contain either roots or children. Preserve policy semantics.
      final groups = <String, List<ReplyInfo>>{};
      for (final reply in response.replies.where((r) => r.root != Int64.ZERO)) {
        groups.putIfAbsent(reply.root.toString(), () => []).add(reply);
      }
      for (final entry in groups.entries) {
        final originalIds = entry.value.map((r) => r.id).toSet();
        dfy.filterChildren(
          entry.value,
          oid: oid,
          type: type,
          rootId: entry.key,
        );
        final keptIds = entry.value.map((r) => r.id).toSet();
        response.replies.removeWhere(
          (r) => originalIds.contains(r.id) && !keptIds.contains(r.id),
        );
      }
      response.replies.removeWhere(needRemoveGrpc);
    }
    return res;
  }

  static Future<LoadingState<DialogListReply>> dialogList({
    required int type,
    required int oid,
    required int root,
    required int dialog,
    required String? offset,
  }) async {
    final dfy = DfyService.instance;
    final session = dfy.sessionFor(oid, type);
    final generation = session.generation;
    final res = await GrpcReq.request(
      GrpcUrl.dialogList,
      DialogListReq(
        oid: Int64(oid),
        type: Int64(type),
        root: Int64(root),
        dialog: Int64(dialog),
        pagination: offset == null ? null : FeedPagination(offset: offset),
      ),
      DialogListReply.fromBuffer,
    );
    // A newer load owns this subject: return the raw payload unfiltered
    // rather than replacing the page with an error.
    if (!_dfyCurrent(session, generation)) return res;
    if (res case Success(:final response)) {
      final owner = response.subjectControl.upMid.toString();
      if (owner != '0') session.ownerMid = owner;
      dfy.filterChildren(
        response.replies,
        oid: oid,
        type: type,
        rootId: root.toString(),
      );
      response.replies.removeWhere(needRemoveGrpc);
    }
    return res;
  }

  static Future<LoadingState<SearchItemReply>> searchItem({
    required int page,
    required SearchItemType itemType,
    required int oid,
    required int type,
    String? keyword,
  }) {
    return GrpcReq.request(
      GrpcUrl.searchItem,
      SearchItemReq(
        cursor: SearchItemCursorReq(
          next: Int64(page),
          itemType: itemType,
        ),
        oid: Int64(oid),
        type: Int64(type),
        keyword: keyword,
      ),
      SearchItemReply.fromBuffer,
    );
  }

  static Future<LoadingState<TranslateReplyResp>> translateReply({
    required Int64 type,
    required Int64 oid,
    required Int64 rpid,
  }) {
    return GrpcReq.request(
      GrpcUrl.translateReply,
      TranslateReplyReq(
        type: type,
        oid: oid,
        rpids: [rpid],
      ),
      TranslateReplyResp.fromBuffer,
    );
  }
}

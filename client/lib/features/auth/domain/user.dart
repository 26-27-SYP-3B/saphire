/// A user, exactly as the server stores it in the "user" table.
/// The password is not part of this model: the server keeps it as a hash and
/// never sends it to the client.
class User {
  const User({required this.id, required this.username});

  final int id;
  final String username;

  // JSON numbers arrive as double on the web, so the cast goes through num.
  factory User.fromJson(Map<String, dynamic> json) => User(
    id: (json['id'] as num).toInt(),
    username: json['username'] as String,
  );
}

/// A user, exactly as the server stores it in the "user" table.
/// The password is not part of this model: the server keeps it as a hash and
/// never sends it to the client.
class User {
  const User({required this.id, required this.username});

  final int id;
  final String username;

  factory User.fromJson(Map<String, dynamic> json) => User(
    id: json['id'] as int,
    username: json['username'] as String,
  );
}
